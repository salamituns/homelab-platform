#!/usr/bin/env bash
# Real-run test harness for scripts/openbao-breakglass.sh (pve-ui-cert-test.sh pattern):
# starts a THROWAWAY non-dev OpenBao server on this Mac (Raft storage in a temp dir,
# init 3 shares / 2 threshold - the same shape as sectools, ADR 0014; verified live
# 2026-11-03: seal-status n=3, t=2), then proves:
#
#   1. flag true blocks generate-root (the production state before the fix);
#   2. SIGHUP does NOT reload the listener flag (why apply-config restarts);
#   3. flag false opens the endpoints after a restart, and the legacy endpoint the bao
#      CLI uses stays gated regardless (why the script speaks the new API);
#   4. --dry-run of every subcommand (apply-config, root-run alertmanager, root-run oidc,
#      root-run watchdog-url) contacts nothing and prompts for nothing;
#   5. the full root-run alertmanager flow through the LOCAL shell override
#      (BREAKGLASS_SSH="bash -c"): hidden-share prompts fed over stdin, the root token
#      minted/decoded/used/revoked, the alertmanager policy, role and secret written,
#      the revocation verified, and no token shape anywhere in the output;
#   6. re-running is idempotent (secret exists -> skip) and revokes again;
#   7. the full root-run oidc grafana flow: same assertions as 5, plus the oidc-read
#      policy, the kubernetes role oidc (monitoring/eso-oidc) and the KV secret written;
#   8. re-running root-run oidc is idempotent (secret exists -> skip) and revokes again;
#   9. root-run oidc oauth2-proxy-prometheus: the 32-byte cookie secret is generated ON
#      the "remote" side (it is never in the payload from the Mac) - proven by the key set;
#   10. the root-run -- <cmd> passthrough works with BAO_TOKEN set;
#   10b. root-run watchdog-url PATCHes only watchdog_url (SMTP keys kept), prints stored (N chars),
#       never prints the URL; a bad prefix is rejected before minting;
#   11. the written objects have the right shape (keys only, never values).
#
# Nothing touches sectools: the "remote" side runs on this Mac via BREAKGLASS_SSH.
# Test shares/password are throwaway. No secret values are printed; the harness prints
# check results and shapes only. Undo: everything lives in one temp dir this script
# removes on exit (CLEANUP=keep keeps it for inspection).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/openbao-breakglass.sh"
CLEANUP="${CLEANUP:-rm}"
TD="$(mktemp -d /tmp/bao-breakglass-test.XXXXXX)"
ADDR="http://127.0.0.1:8288"   # deliberately not 8200/8201
PASS=0; FAIL=0
SERVER_PID=""
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*" >&2; FAIL=$((FAIL+1)); }
check() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }

# Invoked via `trap cleanup EXIT` (shellcheck cannot see trap-indirect calls).
# shellcheck disable=SC2329
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; [[ "$CLEANUP" == rm ]] && rm -rf "$TD"; }
trap cleanup EXIT

export BAO_ADDR="$ADDR"

hcl() {   # $1 = true|false for disable_unauthed_generate_root_endpoints
  cat >"$TD/openbao.hcl" <<EOF
listener "tcp" {
  address = "127.0.0.1:8288"
  tls_disable = true
  disable_unauthed_generate_root_endpoints = $1
}
storage "raft" { path = "$TD/raft" node_id = "test" }
api_addr = "$ADDR"
cluster_addr = "http://127.0.0.1:8289"
EOF
}

start_server() {
  hcl "$1"
  bao server -config="$TD/openbao.hcl" >"$TD/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 30); do
    curl -q -s -o /dev/null "$ADDR/v1/sys/seal-status" && return 0
    sleep 1
  done
  bad "server did not come up"; tail -5 "$TD/server.log"; exit 1
}

unseal_all() {   # 2 of the 3 shares, via the same API the apply-config unseal loop uses
  local i r=""
  for i in 0 1; do
    r=$(jq -r --argjson i "$i" '.unseal_keys_b64[$i]' "$TD/init.json" \
      | jq -Rs '{key: (rtrimstr("\n"))}' | curl -q -s -X PUT --data-binary @- "$ADDR/v1/sys/unseal")
  done
  check "$(jq -r .sealed <<<"$r")" false "unsealed with 2 of 3 shares"
}

probe() {   # poll the attempt endpoint past the sealed/post-unseal races: $1 = wanted code
  local code wanted="$1" i
  for i in $(seq 1 20); do
    code=$(curl -q -s -o /dev/null -w '%{http_code}' "$ADDR/v1/sys/generate-root/attempt")
    [[ "$code" == "$wanted" ]] && { echo "$code"; return 0; }
    [[ "$code" == 000 ]] && sleep 1
  done
  echo "$code"
}

probe_blocked() {   # poll until past 503/000; a block shows as 405 or 500 ("unsupported operation")
  local code i
  for i in $(seq 1 20); do
    code=$(curl -q -s -o /dev/null -w '%{http_code}' "$ADDR/v1/sys/generate-root/attempt")
    if [[ "$code" != 503 && "$code" != 000 ]]; then echo "$code"; return 0; fi
    sleep 1
  done
  echo "$code"
}

run_flow() {   # $1 = output file; remaining args: the subcommand and its args; stdin: prompt answers
  local out="$1"; shift
  BREAKGLASS_SSH="bash -c" BREAKGLASS_BAO_ADDR="$ADDR" "$SCRIPT" "$@" >"$out" 2>&1
}

feed_alert() {   # writes the 2 hidden shares + the 4 alertmanager prompts to a file, echoes the path
  local f; f=$(mktemp "$TD/answers.XXXXXX")
  jq -r '.unseal_keys_b64[0,1]' "$TD/init.json" >"$f"
  printf '%s\n' 'alertuser' 'alerts@home.arpa' 'alerts@home.arpa' 'testapppassword1234' >>"$f"
  echo "$f"
}

feed_shares() {   # writes just the 2 hidden shares
  local f; f=$(mktemp "$TD/answers.XXXXXX")
  jq -r '.unseal_keys_b64[0,1]' "$TD/init.json" >"$f"
  echo "$f"
}

feed_oidc() {   # writes the 2 hidden shares + the 2 hidden oidc prompts (throwaway values)
  local f; f=$(mktemp "$TD/answers.XXXXXX")
  jq -r '.unseal_keys_b64[0,1]' "$TD/init.json" >"$f"
  printf '%s\n' 'test-client-id-throwaway' 'test-client-secret-throwaway' >>"$f"
  echo "$f"
}

# Prefix-valid throwaway ping URL for the local harness only. Not a real check.
WATCHDOG_THROW='https://hc-ping.com/00000000-0000-0000-0000-000000000000'

feed_watchdog() {  # 2 hidden shares + the ping URL (stdin, never argv)
  local f; f=$(mktemp "$TD/answers.XXXXXX")
  jq -r '.unseal_keys_b64[0,1]' "$TD/init.json" >"$f"
  printf '%s\n' "$WATCHDOG_THROW" >>"$f"
  echo "$f"
}

echo "== 1. flag TRUE (the production state before this change) blocks generate-root"
start_server true
bao operator init -key-shares=3 -key-threshold=2 -format=json >"$TD/init.json" 2>/dev/null
unseal_all
BLOCKED="$(probe_blocked)"
if [[ "$BLOCKED" == 405 || "$BLOCKED" == 500 ]]; then
  ok "new-style attempt blocked ($BLOCKED 'unsupported operation'; live sectools shows the same block)"
else
  bad "flag-true attempt not blocked (got $BLOCKED, want 405/500)"
fi

echo "== 2. SIGHUP does NOT reload the listener flag"
hcl false
kill -HUP "$SERVER_PID"
sleep 2
BLOCKED="$(probe_blocked)"
if [[ "$BLOCKED" == 405 || "$BLOCKED" == 500 ]]; then
  ok "still blocked after SIGHUP with flag false ($BLOCKED - restart required)"
else
  bad "SIGHUP apparently reloaded the flag (got $BLOCKED, expected a block)"
fi
check "$(curl -q -s "$ADDR/v1/sys/seal-status" | jq -r .sealed)" false "store stayed unsealed through SIGHUP"

echo "== 3. flag FALSE after a restart opens the endpoints"
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
start_server false
unseal_all
check "$(probe 200)" 200 "new-style attempt open after restart with flag false"
check "$(curl -q -s -o /dev/null -w '%{http_code}' "$ADDR/v1/sys/generate-root-token/attempt")" 403 \
  "legacy endpoint (the one the bao CLI calls) stays gated - why the script uses the new API"
if BAO_TOKEN="$(jq -r .root_token "$TD/init.json")" bao secrets enable -path=secret -version=2 kv >/dev/null 2>&1; then
  ok "kv v2 enabled at secret/ (production prerequisite: openbao-setup-belleshop.sh)"
else
  bad "could not enable kv v2 at secret/"; exit 1
fi
if BAO_TOKEN="$(jq -r .root_token "$TD/init.json")" bao auth enable kubernetes >/dev/null 2>&1; then
  ok "kubernetes auth enabled for the alertmanager flow"
else
  bad "could not enable kubernetes auth"; exit 1
fi

echo "== 4. --dry-run of every subcommand (no contact, no prompts)"
"$SCRIPT" apply-config --dry-run >"$TD/dry1.out" 2>&1
if grep -q "ansible-playbook playbooks/openbao.yml --limit sectools --check --diff" "$TD/dry1.out"; then
  ok "apply-config --dry-run prints the exact playbook commands"
else
  bad "apply-config --dry-run"; cat "$TD/dry1.out"
fi
"$SCRIPT" root-run --dry-run alertmanager >"$TD/dry2.out" 2>&1
if grep -q "revocation" "$TD/dry2.out"; then
  ok "root-run alertmanager --dry-run prints the flow, prompted for nothing"
else
  bad "root-run alertmanager --dry-run"; cat "$TD/dry2.out"
fi
"$SCRIPT" root-run --dry-run oidc grafana >"$TD/dry3.out" 2>&1
if grep -q "revocation" "$TD/dry3.out"; then
  ok "root-run oidc --dry-run prints the flow, prompted for nothing"
else
  bad "root-run oidc --dry-run"; cat "$TD/dry3.out"
fi
"$SCRIPT" root-run --dry-run watchdog-url >"$TD/dry4.out" 2>&1
if grep -q "revocation" "$TD/dry4.out"; then
  ok "root-run watchdog-url --dry-run prints the flow, prompted for nothing"
else
  bad "root-run watchdog-url --dry-run"; cat "$TD/dry4.out"
fi

echo "== 5. root-run alertmanager through the local-shell override (the full flow)"
F1=$(feed_alert)
if run_flow "$TD/run1.out" root-run alertmanager <"$F1"; then
  ok "root-run alertmanager exited 0"
else
  bad "root-run alertmanager failed"; cat "$TD/run1.out"; exit 1
fi
grep -q "verifying the minted token is root" "$TD/run1.out" && ok "minted token verified as root"
grep -q "alertmanager setup complete" "$TD/run1.out" && ok "policy, role and secret written"
grep -q "revocation verified" "$TD/run1.out" && ok "root token revoked and verified revoked"
if grep -qsE '(^|[^a-z])s\.[A-Za-z0-9]{10,}' "$TD/run1.out"; then
  bad "A TOKEN-SHAPED STRING LEAKED INTO THE OUTPUT"
else
  ok "no token shape anywhere in the output"
fi

echo "== 6. re-run is idempotent (secret exists -> skip) and revokes again"
F2=$(feed_alert)
run_flow "$TD/run2.out" root-run alertmanager <"$F2"
if grep -q "already exists" "$TD/run2.out"; then
  ok "second run skips the existing secret"
else
  bad "second run not idempotent"; cat "$TD/run2.out"
fi
grep -q "revocation verified" "$TD/run2.out" && ok "second run also revoked its token"

echo "== 7. root-run oidc grafana through the local-shell override (the full flow)"
F4=$(feed_oidc)
if run_flow "$TD/run4.out" root-run oidc grafana <"$F4"; then
  ok "root-run oidc grafana exited 0"
else
  bad "root-run oidc grafana failed"; cat "$TD/run4.out"; exit 1
fi
grep -q "verifying the minted token is root" "$TD/run4.out" && ok "minted token verified as root (oidc run)"
grep -q "oidc setup complete (grafana)" "$TD/run4.out" && ok "policy, role and secret written (oidc grafana)"
grep -q "revocation verified" "$TD/run4.out" && ok "root token revoked and verified revoked (oidc run)"
if grep -qsE '(^|[^a-z])s\.[A-Za-z0-9]{10,}' "$TD/run4.out"; then
  bad "A TOKEN-SHAPED STRING LEAKED INTO THE OIDC OUTPUT"
else
  ok "no token shape anywhere in the oidc output"
fi

echo "== 8. root-run oidc re-run is idempotent (secret exists -> skip) and revokes again"
F5=$(feed_oidc)
run_flow "$TD/run5.out" root-run oidc grafana <"$F5"
if grep -q "already exists" "$TD/run5.out"; then
  ok "second oidc run skips the existing secret"
else
  bad "second oidc run not idempotent"; cat "$TD/run5.out"
fi
grep -q "revocation verified" "$TD/run5.out" && ok "second oidc run also revoked its token"

echo "== 9. root-run oidc oauth2-proxy-prometheus: cookie secret generated on the remote side"
F6=$(feed_oidc)
if run_flow "$TD/run6.out" root-run oidc oauth2-proxy-prometheus <"$F6"; then
  ok "root-run oidc oauth2-proxy-prometheus exited 0"
else
  bad "root-run oidc oauth2-proxy-prometheus failed"; cat "$TD/run6.out"; exit 1
fi
grep -q "oidc setup complete (oauth2-proxy-prometheus)" "$TD/run6.out" \
  && ok "policy, role and secret written (oauth2-proxy-prometheus)"
# The cookie secret never appears in the Mac-side payload (only client id/secret are prompted
# here); the key-set check below is what proves it was generated and stored remotely.
if grep -q "test-client-secret-throwaway" "$TD/run6.out"; then
  bad "THE CLIENT SECRET WAS PRINTED INTO THE OUTPUT"
else
  ok "client secret never printed in the output"
fi
grep -q "revocation verified" "$TD/run6.out" && ok "oauth2-proxy run revoked its token"

echo "== 10. root-run -- <cmd> passthrough works with BAO_TOKEN set"
F3=$(feed_shares)
run_flow "$TD/run3.out" root-run -- bao auth list <"$F3"
if grep -q "kubernetes/" "$TD/run3.out"; then
  ok "passthrough ran 'bao auth list' with the token"
else
  bad "passthrough failed"; cat "$TD/run3.out"
fi
grep -q "revocation verified" "$TD/run3.out" && ok "passthrough run revoked its token"

echo "== 10b. root-run watchdog-url PATCHes only watchdog_url; bad prefix is rejected"
Fbad=$(feed_shares)
printf '%s\n' 'https://example.invalid/not-hc-ping' >>"$Fbad"
if run_flow "$TD/run-wd-bad.out" root-run watchdog-url <"$Fbad"; then
  bad "bad prefix should have been rejected"
else
  ok "bad prefix rejected (nonzero exit)"
fi
if grep -q "must start with https://hc-ping.com/" "$TD/run-wd-bad.out"; then
  ok "bad prefix error names the required prefix"
else
  bad "bad prefix error missing"; cat "$TD/run-wd-bad.out"
fi
if grep -q "minting the root token" "$TD/run-wd-bad.out"; then
  bad "bad prefix minted a root token (should die locally first)"
else
  ok "bad prefix died before minting"
fi

Fwd=$(feed_watchdog)
if run_flow "$TD/run-wd.out" root-run watchdog-url <"$Fwd"; then
  ok "root-run watchdog-url exited 0"
else
  bad "root-run watchdog-url failed"; cat "$TD/run-wd.out"; exit 1
fi
grep -q "stored (${#WATCHDOG_THROW} chars)" "$TD/run-wd.out" && ok "prints stored (N chars) only"
grep -q "revocation verified" "$TD/run-wd.out" && ok "watchdog-url run revoked its token"
if grep -qF "$WATCHDOG_THROW" "$TD/run-wd.out"; then
  bad "THE PING URL WAS PRINTED INTO THE OUTPUT"
else
  ok "ping URL never printed in the output"
fi
# SMTP values must still be the ones written in step 5 (shape+presence, not printing them).
BAO_TOKEN="$(jq -r .root_token "$TD/init.json")" bao read -format=json secret/data/monitoring/alertmanager \
  | jq -e '.data.data.username == "alertuser"
           and (.data.data | has("password") and has("from") and has("to") and has("watchdog_url"))
           and (.data.data.watchdog_url | startswith("https://hc-ping.com/"))
           and (.data.data.watchdog_url | length == '"${#WATCHDOG_THROW}"')' >/dev/null \
  && ok "watchdog_url patched; SMTP username unchanged"

echo "== 10c. root-run alertmanager still skips after watchdog_url exists"
F7=$(feed_alert)
if run_flow "$TD/run-am-after-wd.out" root-run alertmanager <"$F7"; then
  ok "root-run alertmanager after watchdog-url exited 0"
else
  bad "alertmanager re-run after watchdog_url failed"; cat "$TD/run-am-after-wd.out"
fi
grep -q "already exists" "$TD/run-am-after-wd.out" && ok "alertmanager re-run still skips (does not wipe watchdog_url)"
BAO_TOKEN="$(jq -r .root_token "$TD/init.json")" bao read -format=json secret/data/monitoring/alertmanager \
  | jq -e '.data.data | has("watchdog_url")' >/dev/null \
  && ok "watchdog_url still present after skipped alertmanager write"

echo "== 11. the written objects have the right shape (keys only, never values)"
BAO_TOKEN="$(jq -r .root_token "$TD/init.json")" bao read -format=json secret/data/monitoring/alertmanager \
  | jq -e '.data.data | keys | sort == ["from","password","to","username","watchdog_url"]' >/dev/null \
  && ok "secret/data/monitoring/alertmanager has SMTP keys plus watchdog_url"
BAO_TOKEN="$(jq -r .root_token "$TD/init.json")" bao read -format=json auth/kubernetes/role/alertmanager \
  | jq -e '.data.bound_service_account_names == ["eso-alertmanager"] and .data.bound_service_account_namespaces == ["monitoring"] and .data.token_policies == ["alertmanager-read"]' >/dev/null \
  && ok "auth/kubernetes/role/alertmanager bound to monitoring/eso-alertmanager with alertmanager-read"
BAO_TOKEN="$(jq -r .root_token "$TD/init.json")" bao policy read alertmanager-read >/dev/null \
  && ok "policy alertmanager-read exists"
BAO_TOKEN="$(jq -r .root_token "$TD/init.json")" bao read -format=json secret/data/oidc/grafana \
  | jq -e '.data.data | keys | sort == ["client_id","client_secret"]' >/dev/null \
  && ok "secret/data/oidc/grafana has exactly client_id and client_secret"
BAO_TOKEN="$(jq -r .root_token "$TD/init.json")" bao read -format=json secret/data/oidc/oauth2-proxy-prometheus \
  | jq -e '.data.data | keys | sort == ["client_id","client_secret","cookie_secret"]' >/dev/null \
  && ok "secret/data/oidc/oauth2-proxy-prometheus has client_id, client_secret AND the remotely generated cookie_secret"
BAO_TOKEN="$(jq -r .root_token "$TD/init.json")" bao read -format=json auth/kubernetes/role/oidc \
  | jq -e '.data.bound_service_account_names == ["eso-oidc"] and .data.bound_service_account_namespaces == ["monitoring"] and .data.token_policies == ["oidc-read"]' >/dev/null \
  && ok "auth/kubernetes/role/oidc bound to monitoring/eso-oidc with oidc-read"
BAO_TOKEN="$(jq -r .root_token "$TD/init.json")" bao policy read oidc-read >/dev/null \
  && ok "policy oidc-read exists"

echo ""
echo "result: $PASS passed, $FAIL failed"
if [[ "$FAIL" != 0 ]]; then exit 1; fi
if [[ "$CLEANUP" == keep ]]; then echo "temp dir kept: $TD"; fi
exit 0
