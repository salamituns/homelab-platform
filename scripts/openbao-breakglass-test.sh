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
#      root-run watchdog-url, root-run cloudflared-token, root-run public-site-probes) contacts nothing and prompts for nothing;
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
#   11. the written objects have the right shape (keys only, never values);
#   15. root-run govgraph-secrets: staging/prod writes (DATABASE_URL hidden-prompted,
#       CRON_SECRET generated on the "remote" side, 64 hex), re-run skips without
#       --overwrite and regenerates CRON_SECRET with it, prod also writes the cloudflare
#       object, bad values die before minting, --dry-run prompts nothing (stdin closed),
#       and the secret values never appear in the ssh boundary's argv log, any local or
#       remote jq argv, or any transcript. Also: a DATABASE_URL whose password contains
#       '/' is rejected without leaking any fragment, internal whitespace in
#       DATABASE_URL/CF_API_TOKEN is rejected (only edges are trimmed), the skip path
#       verifies the stored key set + CRON_SECRET shape instead of trusting metadata,
#       --overwrite-app rotates only the app object, --overwrite-cloudflare rotates only
#       the prod cloudflare object (CRON_SECRET kept byte-for-byte; each prompts only
#       for the object it writes), and the split flags refuse bad combinations (together /
#       staging cloudflare / wrong mode) before minting. The payload rides ssh stdin into
#       a non-exported variable: root-run -- env shows no share, the remote shell's
#       exec-time environment (ps eww) holds neither share nor payload variable, and
#       --overwrite-app with a missing cloudflare object refuses BEFORE any write;
#   16. root-run govgraph-probes: PATCHes govgraph_apex_url+govgraph_staging_url into the
#       shared public-site-probes object (all four keys afterwards, public keys untouched)
#       with a KV v2 check-and-set on the version just read, refuses without --overwrite,
#       refuses a stray key before writing (without --overwrite; with it the canonical
#       write drops the stray key - same for public-site-probes - so removing one never
#       needs a raw argv write), refuses an empty stored govgraph URL on the keep path,
#       --overwrite repairs a lone govgraph key, a missing base pair is refused by
#       govgraph-probes and repaired by public-site-probes --overwrite, and a soft-deleted
#       latest version (data 404, metadata 200) is rebuilt by public-site-probes
#       --overwrite, public-site-probes --overwrite afterwards KEEPS the govgraph keys, a missing
#       trailing slash dies before minting, --dry-run prompts nothing (stdin closed), the
#       server rejects a stale check-and-set write (HTTP 400), and no probe URL or unseal
#       share rides argv or any transcript.
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
"$SCRIPT" root-run --dry-run cloudflared-token >"$TD/dry5.out" 2>&1
if grep -q "revocation" "$TD/dry5.out"; then
  ok "root-run cloudflared-token --dry-run prints the flow, prompted for nothing"
else
  bad "root-run cloudflared-token --dry-run"; cat "$TD/dry5.out"
fi
"$SCRIPT" root-run --dry-run public-site-probes >"$TD/dry6.out" 2>&1
if grep -q "revocation" "$TD/dry6.out"; then
  ok "root-run public-site-probes --dry-run prints the flow, prompted for nothing"
else
  bad "root-run public-site-probes --dry-run"; cat "$TD/dry6.out"
fi
"$SCRIPT" root-run --dry-run govgraph-secrets staging </dev/null >"$TD/dry7.out" 2>&1
if grep -q "revocation" "$TD/dry7.out" && grep -q "secret/apps/govgraph/staging/app" "$TD/dry7.out" \
  && grep -q "generated on sectools" "$TD/dry7.out" && grep -qi "no cloudflare object" "$TD/dry7.out"; then
  ok "root-run govgraph-secrets staging --dry-run prints the plan, prompts nothing (stdin was closed)"
else
  bad "root-run govgraph-secrets staging --dry-run"; cat "$TD/dry7.out"
fi
"$SCRIPT" root-run --dry-run govgraph-secrets prod </dev/null >"$TD/dry8.out" 2>&1
if grep -q "revocation" "$TD/dry8.out" && grep -q "secret/apps/govgraph/prod/app" "$TD/dry8.out" \
  && grep -q "secret/apps/govgraph/prod/cloudflare" "$TD/dry8.out" && grep -q "generated on sectools" "$TD/dry8.out"; then
  ok "root-run govgraph-secrets prod --dry-run prints both paths, prompts nothing (stdin was closed)"
else
  bad "root-run govgraph-secrets prod --dry-run"; cat "$TD/dry8.out"
fi
"$SCRIPT" root-run --dry-run govgraph-probes </dev/null >"$TD/dry9.out" 2>&1
if grep -q "revocation" "$TD/dry9.out" && grep -q "secret/monitoring/public-site-probes" "$TD/dry9.out" \
  && grep -q "govgraph_apex_url" "$TD/dry9.out" && grep -qi "kept untouched" "$TD/dry9.out"; then
  ok "root-run govgraph-probes --dry-run prints the PATCH plan, prompts nothing (stdin was closed)"
else
  bad "root-run govgraph-probes --dry-run"; cat "$TD/dry9.out"
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

echo "== 10a. a bare unknown mode is refused before any share is asked or token minted"
# 2026-11-09, twice: a mode missing from a stale checkout fell through to "run it as a command".
Fu=$(feed_shares)
if run_flow "$TD/run-unknown.out" root-run public-site-probes-typo <"$Fu"; then
  bad "unknown bare mode should be refused"
else
  ok "unknown bare mode refused (nonzero exit)"
fi
if grep -q "unknown root-run mode" "$TD/run-unknown.out" && grep -q "git pull" "$TD/run-unknown.out"; then
  ok "refusal names the problem and suggests git pull"
else
  bad "refusal message missing"; cat "$TD/run-unknown.out"
fi
if grep -qE "unseal share|minting the root token" "$TD/run-unknown.out"; then
  bad "unknown mode got as far as shares / minting"
else
  ok "unknown mode stopped before shares and minting"
fi
# `--` after a word is not an escape hatch: the word is still treated as a mode name.
if run_flow "$TD/run-unknown2.out" root-run bao -- auth list <"$Fu"; then
  bad "'root-run bao -- ...' should be refused (-- must come first)"
else
  ok "'--' only opens command mode when it comes first"
fi

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

echo "== 12. root-run nexus-pull and root-run tenant (ADR 0019 Phase 0)"
feed_shares() { local f; f=$(mktemp "$TD/answers.XXXXXX"); jq -r '.unseal_keys_b64[0,1]' "$TD/init.json" >"$f"; echo "$f"; }
FAKE_PW="harness-fake-pull-pw-$RANDOM$RANDOM"
export BREAKGLASS_NEXUS_PULL_CMD="printf %s $FAKE_PW"
F12=$(feed_shares)
if run_flow "$TD/run-np.out" root-run nexus-pull <"$F12"; then ok "root-run nexus-pull exited 0"; else bad "root-run nexus-pull failed"; cat "$TD/run-np.out"; fi
unset BREAKGLASS_NEXUS_PULL_CMD
grep -q "nexus-pull setup complete" "$TD/run-np.out" && ok "nexus-pull policy, roles and secret written"
grep -q "revocation verified" "$TD/run-np.out" && ok "nexus-pull run revoked its token"
if grep -qF "$FAKE_PW" "$TD/run-np.out"; then bad "THE PULL PASSWORD LEAKED INTO THE OUTPUT"; else ok "pull password never printed"; fi
F13=$(feed_shares)
export BREAKGLASS_NEXUS_PULL_CMD="printf %s different-value"
run_flow "$TD/run-np2.out" root-run nexus-pull <"$F13" || true
unset BREAKGLASS_NEXUS_PULL_CMD
if grep -q "already exists" "$TD/run-np2.out"; then ok "nexus-pull re-run skips the existing secret (no --overwrite)"; else bad "nexus-pull re-run did not skip"; cat "$TD/run-np2.out"; fi
F14=$(feed_shares)
if run_flow "$TD/run-tn.out" root-run tenant demo staging <"$F14"; then ok "root-run tenant demo staging exited 0"; else bad "root-run tenant failed"; cat "$TD/run-tn.out"; fi
grep -q "revocation verified" "$TD/run-tn.out" && ok "tenant run revoked its token"
if run_flow "$TD/run-tn-bad.out" root-run tenant 'Demo;rm' staging </dev/null; then bad "bad tenant name accepted"; else ok "bad tenant name rejected locally"; fi
RT="$(jq -r .root_token "$TD/init.json")"
if BAO_TOKEN="$RT" bao read -format=json secret/data/platform/nexus-pull \
  | jq -e --arg pw "$FAKE_PW" '.data.data | (keys == ["password","username"]) and .username == "k8s-pull" and .password == $pw' >/dev/null; then
  ok "secret/platform/nexus-pull holds k8s-pull + the FIRST password (re-run did not overwrite)"
else
  bad "secret/platform/nexus-pull shape or value wrong"
fi
for NS in dev kyverno argo-rollouts; do
  BAO_TOKEN="$RT" bao read -format=json "auth/kubernetes/role/nexus-pull-$NS" \
    | jq -e --arg ns "$NS" '.data.bound_service_account_names == ["eso-nexus-pull"] and .data.bound_service_account_namespaces == [$ns] and .data.token_policies == ["nexus-pull-read"]' >/dev/null \
    && ok "role nexus-pull-$NS bound to $NS/eso-nexus-pull with nexus-pull-read"
done
BAO_TOKEN="$RT" bao policy read nexus-pull-read | grep -q 'secret/data/platform/nexus-pull' && ok "policy nexus-pull-read grants the pull credential path"
[[ "$(BAO_TOKEN="$RT" bao policy read nexus-pull-read | grep -c '^path')" == 1 ]] && ok "policy nexus-pull-read has exactly one path"
BAO_TOKEN="$RT" bao read -format=json auth/kubernetes/role/tenant-demo-staging \
  | jq -e '.data.bound_service_account_names == ["eso"] and .data.bound_service_account_namespaces == ["demo-staging"] and .data.token_policies == ["tenant-demo-staging"]' >/dev/null \
  && ok "role tenant-demo-staging bound to demo-staging/eso with tenant-demo-staging"
TP="$(BAO_TOKEN="$RT" bao policy read tenant-demo-staging)"
grep -q 'secret/data/apps/demo/staging/\*' <<<"$TP" && grep -q 'secret/data/platform/nexus-pull' <<<"$TP" \
  && [[ "$(grep -c '^path' <<<"$TP")" == 2 ]] && ok "policy tenant-demo-staging grants exactly its own path + the pull credential"
# Least privilege, proven with a token carrying ONLY the tenant policy:
TT="$(BAO_TOKEN="$RT" bao token create -policy=tenant-demo-staging -ttl=5m -field=token)"
BAO_TOKEN="$RT" bao kv put secret/apps/demo/staging/web k=v >/dev/null && BAO_TOKEN="$RT" bao kv put secret/apps/other/staging/web k=v >/dev/null
BAO_TOKEN="$TT" bao kv get secret/apps/demo/staging/web >/dev/null 2>&1 && ok "tenant token CAN read its own path"
if BAO_TOKEN="$TT" bao kv get secret/apps/other/staging/web >/dev/null 2>&1; then bad "TENANT TOKEN READ ANOTHER TENANT'S SECRET"; else ok "tenant token CANNOT read another tenant's path (403)"; fi
if BAO_TOKEN="$TT" bao kv get secret/monitoring/alertmanager >/dev/null 2>&1; then bad "TENANT TOKEN READ A PLATFORM SECRET"; else ok "tenant token CANNOT read platform secrets"; fi
unset RT TT TP

echo "== 13. root-run cloudflared-token (ADR 0019 D7); bad shape dies before mint"
# Throwaway token in Cloudflare's real format, built at runtime so no secret-shaped literal
# sits in git: standard base64 of {"a","t","s"} (cloudflared TunnelToken.Encode). Not real.
CF_THROW=$(python3 -c 'import base64, json, uuid
print(base64.b64encode(json.dumps({"a": "0"*32, "t": str(uuid.uuid4()), "s": base64.b64encode(b"harness"*6).decode()}).encode()).decode())
')
# A JWT-shaped paste (what the first version wrongly demanded) must now be refused.
# shellcheck disable=SC2034  # read indirectly via ${!bad_tok} below
CF_JWT=$(python3 -c 'import base64
h=base64.urlsafe_b64encode(b"{\"alg\":\"none\"}").rstrip(b"=").decode()
print(h+"."+h+"."+("x"*80))
')
# base64 JSON without the tunnel fields must be refused too.
# shellcheck disable=SC2034  # read indirectly via ${!bad_tok} below
CF_NOFIELDS=$(python3 -c 'import base64, json; print(base64.b64encode(json.dumps({"x": 1}).encode()).decode())')
for bad_tok in CF_JWT CF_NOFIELDS; do
  Fb=$(feed_shares); printf '%s\n' "${!bad_tok}" >>"$Fb"
  if run_flow "$TD/run-cf-$bad_tok.out" root-run cloudflared-token <"$Fb"; then
    bad "$bad_tok tunnel token should have been rejected"
  elif grep -q "minting the root token" "$TD/run-cf-$bad_tok.out"; then
    bad "$bad_tok tunnel token minted a root token (should die locally first)"
  else
    ok "$bad_tok tunnel token rejected before minting"
  fi
done
Fcfbad=$(feed_shares)
printf '%s\n' "$(python3 -c 'print("x"*120)')" >>"$Fcfbad"
if run_flow "$TD/run-cf-bad.out" root-run cloudflared-token <"$Fcfbad"; then
  bad "bad tunnel token should have been rejected"
else
  ok "bad tunnel token rejected (nonzero exit)"
fi
if grep -q "must start with eyJ" "$TD/run-cf-bad.out"; then
  ok "bad token error names the expected eyJ prefix"
else
  bad "bad token error missing"; cat "$TD/run-cf-bad.out"
fi
if grep -q "minting the root token" "$TD/run-cf-bad.out"; then
  bad "bad tunnel token minted a root token (should die locally first)"
else
  ok "bad tunnel token died before minting"
fi

feed_cloudflared() {
  local f; f=$(mktemp "$TD/answers.XXXXXX")
  jq -r '.unseal_keys_b64[0,1]' "$TD/init.json" >"$f"
  printf '%s\n' "$CF_THROW" >>"$f"
  echo "$f"
}
Fcf=$(feed_cloudflared)
if run_flow "$TD/run-cf.out" root-run cloudflared-token <"$Fcf"; then
  ok "root-run cloudflared-token exited 0"
else
  bad "root-run cloudflared-token failed"; cat "$TD/run-cf.out"; exit 1
fi
grep -q "stored (${#CF_THROW} chars)" "$TD/run-cf.out" && ok "prints stored (N chars) only"
grep -q "cloudflared-token setup complete" "$TD/run-cf.out" && ok "cloudflared policy, role and secret written"
grep -q "revocation verified" "$TD/run-cf.out" && ok "cloudflared-token run revoked its token"
if grep -qF "$CF_THROW" "$TD/run-cf.out"; then
  bad "THE TUNNEL TOKEN WAS PRINTED INTO THE OUTPUT"
else
  ok "tunnel token never printed in the output"
fi
Fcf2=$(feed_cloudflared)
run_flow "$TD/run-cf2.out" root-run cloudflared-token <"$Fcf2" || true
if grep -q "already exists" "$TD/run-cf2.out"; then
  ok "cloudflared-token re-run skips the existing secret (no --overwrite)"
else
  bad "cloudflared-token re-run did not skip"; cat "$TD/run-cf2.out"
fi
RT="$(jq -r .root_token "$TD/init.json")"
BAO_TOKEN="$RT" bao read -format=json secret/data/platform/cloudflared \
  | jq -e --arg t "$CF_THROW" '.data.data | (keys == ["tunnel_token"]) and .tunnel_token == $t' >/dev/null \
  && ok "secret/platform/cloudflared holds tunnel_token of the first write"
BAO_TOKEN="$RT" bao read -format=json auth/kubernetes/role/cloudflared \
  | jq -e '.data.bound_service_account_names == ["eso"] and .data.bound_service_account_namespaces == ["edge-public"] and .data.token_policies == ["cloudflared-read"]' >/dev/null \
  && ok "role cloudflared bound to edge-public/eso with cloudflared-read"
BAO_TOKEN="$RT" bao policy read cloudflared-read | grep -q 'secret/data/platform/cloudflared' \
  && [[ "$(BAO_TOKEN="$RT" bao policy read cloudflared-read | grep -c '^path')" == 1 ]] \
  && ok "policy cloudflared-read grants exactly the tunnel-token path"
unset RT

echo "== 14. root-run public-site-probes; bad shape dies before mint"
PS_APEX='https://apex.example/'
PS_STAGING='https://staging.example/'
Fpsbad=$(feed_shares)
printf '%s\n' 'http://apex.example/' 'https://staging.example/' >>"$Fpsbad"
if run_flow "$TD/run-ps-bad.out" root-run public-site-probes <"$Fpsbad"; then
  bad "http:// apex URL should have been rejected"
else
  ok "http:// apex URL rejected (nonzero exit)"
fi
if grep -q "minting the root token" "$TD/run-ps-bad.out"; then
  bad "bad public-site URL minted a root token (should die locally first)"
else
  ok "bad public-site URL died before minting"
fi
Fpsip=$(feed_shares)
printf '%s\n' 'https://192.168.1.1/' 'https://staging.example/' >>"$Fpsip"
if run_flow "$TD/run-ps-ip.out" root-run public-site-probes <"$Fpsip"; then
  bad "RFC1918 apex URL should have been rejected"
elif grep -q "minting the root token" "$TD/run-ps-ip.out"; then
  bad "RFC1918 apex URL minted a root token"
else
  ok "RFC1918 apex URL rejected before minting"
fi
feed_publicsite() {
  local f; f=$(mktemp "$TD/answers.XXXXXX")
  jq -r '.unseal_keys_b64[0,1]' "$TD/init.json" >"$f"
  printf '%s\n' "$PS_APEX" "$PS_STAGING" >>"$f"
  echo "$f"
}
Fps=$(feed_publicsite)
if run_flow "$TD/run-ps.out" root-run public-site-probes <"$Fps"; then
  ok "root-run public-site-probes exited 0"
else
  bad "root-run public-site-probes failed"; cat "$TD/run-ps.out"; exit 1
fi
grep -q "stored (apex ${#PS_APEX} chars, staging ${#PS_STAGING} chars)" "$TD/run-ps.out" && ok "prints stored (N chars) only"
grep -q "public-site-probes setup complete" "$TD/run-ps.out" && ok "public-site-probes policy, role and secret written"
grep -q "revocation verified" "$TD/run-ps.out" && ok "public-site-probes run revoked its token"
if grep -qF "$PS_APEX" "$TD/run-ps.out" || grep -qF "$PS_STAGING" "$TD/run-ps.out"; then
  bad "A PROBE URL WAS PRINTED INTO THE OUTPUT"
else
  ok "probe URLs never printed in the output"
fi
Fps2=$(feed_publicsite)
run_flow "$TD/run-ps2.out" root-run public-site-probes <"$Fps2" || true
if grep -q "already exists" "$TD/run-ps2.out"; then
  ok "public-site-probes re-run skips the existing secret (no --overwrite)"
else
  bad "public-site-probes re-run did not skip"; cat "$TD/run-ps2.out"
fi
RT="$(jq -r .root_token "$TD/init.json")"
BAO_TOKEN="$RT" bao read -format=json secret/data/monitoring/public-site-probes \
  | jq -e --arg a "$PS_APEX" --arg s "$PS_STAGING" \
    '.data.data | (keys == ["apex_url","staging_url"]) and .apex_url == $a and .staging_url == $s' >/dev/null \
  && ok "secret/monitoring/public-site-probes holds both URLs of the first write"
BAO_TOKEN="$RT" bao read -format=json auth/kubernetes/role/public-site-probes \
  | jq -e '.data.bound_service_account_names == ["eso-public-site-probes"] and .data.bound_service_account_namespaces == ["monitoring"] and .data.token_policies == ["public-site-probes-read"]' >/dev/null \
  && ok "role public-site-probes bound to monitoring/eso-public-site-probes"
BAO_TOKEN="$RT" bao policy read public-site-probes-read | grep -q 'secret/data/monitoring/public-site-probes' \
  && [[ "$(BAO_TOKEN="$RT" bao policy read public-site-probes-read | grep -c '^path')" == 1 ]] \
  && ok "policy public-site-probes-read grants exactly the probe-URL path"
unset RT

echo "== 15. root-run govgraph-secrets: argv-free writes, overwrite, validation"
# An argv-logging shim on the ssh boundary: it records every argv word that crosses the
# boundary (stdin is never argv), so the test can prove no secret value ever rides argv.
# The log path is baked into the shim: $TD is not exported into the shim's environment.
cat >"$TD/ssh-shim" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$TD/ssh-argv.log"
exec "\$@"
SHIM
chmod +x "$TD/ssh-shim"
# A second argv-logging shim, this one on jq itself. In this harness BOTH sides run on
# this Mac (the remote side is BREAKGLASS_SSH="bash -c" and inherits the environment),
# so the wrapper records every argv word of every jq call either side makes. Values that
# ride jq's --arg/--argjson would land in this log; values passed through the environment
# (the pattern the sweep converted everything to) never do. The real jq path and the log
# path are baked into the wrapper for the same reason as the ssh shim.
REAL_JQ="$(command -v jq)"
mkdir -p "$TD/bin"
cat >"$TD/bin/jq" <<JQSHIM
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$TD/jq-argv.log"
exec "$REAL_JQ" "\$@"
JQSHIM
chmod +x "$TD/bin/jq"
run_flow_shim() {  # like run_flow, but the ssh boundary logs its argv and jq does too
  local out="$1"; shift
  PATH="$TD/bin:$PATH" BREAKGLASS_SSH="$TD/ssh-shim bash -c" BREAKGLASS_BAO_ADDR="$ADDR" "$SCRIPT" "$@" >"$out" 2>&1
}
GG_DB='postgres://ggtest:throwaway@127.0.0.1:6543/postgres'
GG_BAD_PORT='postgres://ggtest:throwaway@127.0.0.1:5433/postgres'
GG_ZONE='a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6'
GG_TOKEN='cf-api-token-throwaway'
SHARE1="$(jq -r '.unseal_keys_b64[0]' "$TD/init.json")"  # a real share, for the jq argv audit
feed_govgraph() {  # $@ = every prompt line after the 2 shares
  local f; f=$(mktemp "$TD/answers.XXXXXX")
  jq -r '.unseal_keys_b64[0,1]' "$TD/init.json" >"$f"
  printf '%s\n' "$@" >>"$f"
  echo "$f"
}

echo "== 15a. bad DATABASE_URL port and bad CF_ZONE_ID die before minting (nothing written)"
RT="$(jq -r .root_token "$TD/init.json")"
Fgga=$(feed_govgraph "$GG_BAD_PORT")
if run_flow "$TD/run-gg-badport.out" root-run govgraph-secrets staging <"$Fgga"; then
  bad "bad DATABASE_URL port accepted"
else
  ok "bad DATABASE_URL port rejected (nonzero exit)"
fi
if grep -q "port 5432 or 6543" "$TD/run-gg-badport.out"; then
  ok "bad port error names the allowed ports"
else
  bad "bad port error missing"; cat "$TD/run-gg-badport.out"
fi
if grep -q "minting the root token" "$TD/run-gg-badport.out"; then
  bad "bad port minted a root token (should die locally first)"
else
  ok "bad port died before minting"
fi
Fggb=$(feed_govgraph "$GG_DB" 'zz-not-32-hex' "$GG_TOKEN")
if run_flow "$TD/run-gg-badzone.out" root-run govgraph-secrets prod <"$Fggb"; then
  bad "bad CF_ZONE_ID accepted"
else
  ok "bad CF_ZONE_ID rejected (nonzero exit)"
fi
if grep -q "32 hex" "$TD/run-gg-badzone.out"; then
  ok "bad CF_ZONE_ID error names the expected shape"
else
  bad "bad zone error missing"; cat "$TD/run-gg-badzone.out"
fi
if grep -q "minting the root token" "$TD/run-gg-badzone.out"; then
  bad "bad zone minted a root token (should die locally first)"
else
  ok "bad zone died before minting"
fi
if BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/staging/app >/dev/null 2>&1; then
  bad "the rejected staging run WROTE an object"
else
  ok "no staging object exists after the rejected runs"
fi
if BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/prod/cloudflare >/dev/null 2>&1; then
  bad "the rejected prod run WROTE an object"
else
  ok "no prod object exists after the rejected runs"
fi

echo "== 15b. staging write: both keys, remotely generated CRON_SECRET, argv and transcript clean"
Fggc=$(feed_govgraph "$GG_DB")
if run_flow_shim "$TD/run-ggs.out" root-run govgraph-secrets staging <"$Fggc"; then
  ok "root-run govgraph-secrets staging exited 0"
else
  bad "root-run govgraph-secrets staging failed"; cat "$TD/run-ggs.out"; exit 1
fi
if grep -q "govgraph-secrets setup complete (staging)" "$TD/run-ggs.out"; then ok "staging app object written"; else bad "staging completion line missing"; fi
if [[ -s "$TD/ssh-argv.log" ]] && grep -q '^bash -s$' "$TD/ssh-argv.log"; then
  ok "ssh-boundary argv logger captured the boundary traffic (positive control)"
else
  bad "ssh-boundary argv log is missing/empty - the argv checks are vacuous"
fi
if [[ -s "$TD/jq-argv.log" ]] && grep -q "fromjson" "$TD/jq-argv.log"; then
  ok "jq argv logger captured local+remote jq traffic (positive control)"
else
  bad "jq argv log is missing/empty/no fromjson - the jq argv checks are vacuous"
fi
if grep -qF "$SHARE1" "$TD/jq-argv.log"; then
  bad "AN UNSEAL SHARE APPEARED IN A LOCAL/REMOTE JQ ARGV"
else
  ok "unseal shares never ride a local/remote jq argv (payload passes through the environment)"
fi
if grep -qF "$GG_DB" "$TD/jq-argv.log"; then
  bad "DATABASE_URL APPEARED IN A LOCAL/REMOTE JQ ARGV"
else
  ok "DATABASE_URL never rides a local/remote jq argv"
fi
if grep -q "keys: DATABASE_URL, CRON_SECRET (version 1)" "$TD/run-ggs.out"; then ok "prints only key names + version 1"; else bad "key/version line missing"; fi
if grep -q "revocation verified" "$TD/run-ggs.out"; then ok "staging run revoked its token"; else bad "staging revocation missing"; fi
if grep -qF "$GG_DB" "$TD/ssh-argv.log"; then
  bad "DATABASE_URL APPEARED IN THE SSH BOUNDARY'S ARGV"
else
  ok "DATABASE_URL never crosses the ssh boundary on argv"
fi
if grep -qF "$GG_DB" "$TD/run-ggs.out"; then
  bad "DATABASE_URL WAS PRINTED INTO THE TRANSCRIPT"
else
  ok "DATABASE_URL never printed"
fi
GG_CRON_1="$(BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/staging/app | jq -r .data.data.CRON_SECRET)"
if [[ "$GG_CRON_1" =~ ^[0-9a-f]{64}$ ]]; then
  ok "CRON_SECRET is 64 hex characters (generated on sectools; the feed supplied no value for it)"
else
  bad "CRON_SECRET is not 64 hex characters"
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/staging/app \
  | jq -e --arg db "$GG_DB" '.data.data | (keys | sort == ["CRON_SECRET","DATABASE_URL"]) and .DATABASE_URL == $db' >/dev/null \
  && ok "staging object holds exactly the prompted DATABASE_URL + the generated CRON_SECRET"
if BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/staging/cloudflare >/dev/null 2>&1; then
  bad "STAGING WROTE A CLOUDFLARE OBJECT"
else
  ok "staging wrote no cloudflare object"
fi

echo "== 15c. re-run refuses without --overwrite (CRON_SECRET kept); --overwrite regenerates it"
Fggd=$(feed_govgraph "$GG_DB")
run_flow_shim "$TD/run-ggs2.out" root-run govgraph-secrets staging <"$Fggd" || true
if grep -q "already exists" "$TD/run-ggs2.out"; then
  ok "second staging run refuses the existing object"
else
  bad "second staging run did not refuse"; cat "$TD/run-ggs2.out"
fi
GG_CRON_2="$(BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/staging/app | jq -r .data.data.CRON_SECRET)"
if [[ "$GG_CRON_2" == "$GG_CRON_1" ]]; then
  ok "CRON_SECRET kept (web and refresh stay in agreement)"
else
  bad "CRON_SECRET CHANGED WITHOUT --overwrite"
fi
Fgge=$(feed_govgraph "$GG_DB")
if run_flow_shim "$TD/run-ggs3.out" root-run govgraph-secrets staging --overwrite <"$Fgge"; then
  ok "staging --overwrite exited 0"
else
  bad "staging --overwrite failed"; cat "$TD/run-ggs3.out"; exit 1
fi
GG_CRON_3="$(BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/staging/app | jq -r .data.data.CRON_SECRET)"
if [[ "$GG_CRON_3" =~ ^[0-9a-f]{64}$ && "$GG_CRON_3" != "$GG_CRON_1" ]]; then
  ok "--overwrite regenerated CRON_SECRET (still 64 hex)"
else
  bad "--overwrite did not regenerate CRON_SECRET"
fi
if grep -q "keys: DATABASE_URL, CRON_SECRET (version 2)" "$TD/run-ggs3.out"; then ok "--overwrite prints version 2"; else bad "--overwrite version line missing"; fi

echo "== 15d. prod writes both objects; values never in argv or transcripts"
Fggf=$(feed_govgraph "$GG_DB" "$GG_ZONE" "$GG_TOKEN")
if run_flow_shim "$TD/run-ggp.out" root-run govgraph-secrets prod <"$Fggf"; then
  ok "root-run govgraph-secrets prod exited 0"
else
  bad "root-run govgraph-secrets prod failed"; cat "$TD/run-ggp.out"; exit 1
fi
if grep -q "govgraph-secrets setup complete (prod)" "$TD/run-ggp.out"; then ok "prod run completed"; else bad "prod completion line missing"; fi
if grep -q "secret/apps/govgraph/prod/app keys: DATABASE_URL, CRON_SECRET (version 1)" "$TD/run-ggp.out"; then ok "prod app object written, key names + version printed"; else bad "prod app key/version line missing"; fi
if grep -q "secret/apps/govgraph/prod/cloudflare keys: CF_ZONE_ID, CF_API_TOKEN (version 1)" "$TD/run-ggp.out"; then ok "prod cloudflare object written, key names + version printed"; else bad "prod cloudflare key/version line missing"; fi
if grep -qF "$GG_DB" "$TD/ssh-argv.log" || grep -qF "$GG_TOKEN" "$TD/ssh-argv.log" || grep -qF "$GG_ZONE" "$TD/ssh-argv.log"; then
  bad "A GOVGRAPH SECRET APPEARED IN THE SSH BOUNDARY'S ARGV"
else
  ok "prod secrets never cross the ssh boundary on argv"
fi
if grep -qF "$GG_DB" "$TD/run-ggp.out" || grep -qF "$GG_TOKEN" "$TD/run-ggp.out" || grep -qF "$GG_ZONE" "$TD/run-ggp.out"; then
  bad "A GOVGRAPH SECRET WAS PRINTED INTO THE TRANSCRIPT"
else
  ok "prod secrets never printed"
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/prod/app \
  | jq -e --arg db "$GG_DB" '.data.data | (keys | sort == ["CRON_SECRET","DATABASE_URL"]) and .DATABASE_URL == $db' >/dev/null \
  && ok "prod app object holds the prompted DATABASE_URL + a generated CRON_SECRET"
BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/prod/cloudflare \
  | jq -e --arg z "$GG_ZONE" --arg t "$GG_TOKEN" \
    '.data.data | (keys | sort == ["CF_API_TOKEN","CF_ZONE_ID"]) and .CF_ZONE_ID == $z and .CF_API_TOKEN == $t' >/dev/null \
  && ok "prod cloudflare object holds the prompted CF_ZONE_ID + CF_API_TOKEN"
if grep -qF "$GG_ZONE" "$TD/jq-argv.log" || grep -qF "$GG_TOKEN" "$TD/jq-argv.log"; then
  bad "A CF VALUE APPEARED IN A LOCAL/REMOTE JQ ARGV"
else
  ok "CF values never ride a local/remote jq argv"
fi
if grep -q "revocation verified" "$TD/run-ggp.out"; then ok "prod run revoked its token"; else bad "prod revocation missing"; fi

echo "== 15e. a DATABASE_URL whose password contains '/' is rejected WITHOUT leaking a fragment"
# urlparse raises a ValueError that names the offending fragment on this shape ('Port
# could not be cast to integer value as ...'); the validator must swallow it and print
# only the fixed allowed-ports message.
GG_DB_SLASH='postgres://ggtest:pwn/dZk9secret@127.0.0.1:5432/postgres'
F15e=$(feed_govgraph "$GG_DB_SLASH")
if run_flow "$TD/run-gg-slash.out" root-run govgraph-secrets staging <"$F15e"; then
  bad "DATABASE_URL with a '/' in the password accepted"
else
  ok "DATABASE_URL with a '/' in the password rejected (nonzero exit)"
fi
if grep -q "port 5432 or 6543" "$TD/run-gg-slash.out"; then
  ok "slash-password error is the fixed allowed-ports message"
else
  bad "slash-password error message missing"; cat "$TD/run-gg-slash.out"
fi
if grep -qF 'dZk9secret' "$TD/run-gg-slash.out" || grep -qF 'ggtest:pwn' "$TD/run-gg-slash.out"; then
  bad "PASSWORD FRAGMENT LEAKED INTO THE TRANSCRIPT"
else
  ok "no password fragment appears anywhere in the transcript"
fi
if grep -q "minting the root token" "$TD/run-gg-slash.out"; then
  bad "slash-password run minted a root token (should die locally first)"
else
  ok "slash-password run died before minting"
fi

echo "== 15f. internal whitespace in DATABASE_URL/CF_API_TOKEN is rejected, not stripped-and-stored"
GG_DB_SPACE='postgres://ggtest/throw away@127.0.0.1:5432/postgres'
F15f=$(feed_govgraph "$GG_DB_SPACE")
if run_flow "$TD/run-gg-space.out" root-run govgraph-secrets staging <"$F15f"; then
  bad "DATABASE_URL with internal whitespace accepted"
else
  ok "DATABASE_URL with internal whitespace rejected (nonzero exit)"
fi
if grep -q "DATABASE_URL must not contain whitespace" "$TD/run-gg-space.out"; then
  ok "the whitespace error names the rule (the value is refused, not silently changed)"
else
  bad "DATABASE_URL whitespace error missing"; cat "$TD/run-gg-space.out"
fi
if grep -q "minting the root token" "$TD/run-gg-space.out"; then
  bad "whitespace run minted a root token (should die locally first)"
else
  ok "whitespace run died before minting"
fi
F15f2=$(feed_govgraph "$GG_DB" "$GG_ZONE" 'cf-api-token with spaces')
if run_flow "$TD/run-gg-cfspace.out" root-run govgraph-secrets prod <"$F15f2"; then
  bad "CF_API_TOKEN with internal whitespace accepted"
else
  ok "CF_API_TOKEN with internal whitespace rejected (nonzero exit)"
fi
if grep -q "CF_API_TOKEN must not contain whitespace" "$TD/run-gg-cfspace.out"; then
  ok "CF_API_TOKEN whitespace error names the rule"
else
  bad "CF_API_TOKEN whitespace error missing"; cat "$TD/run-gg-cfspace.out"
fi
if grep -q "minting the root token" "$TD/run-gg-cfspace.out"; then
  bad "CF whitespace run minted a root token (should die locally first)"
else
  ok "CF whitespace run died before minting"
fi

echo "== 15g. leading/trailing whitespace is trimmed (accepted); the stored value is the trimmed one"
F15g=$(feed_govgraph "  $GG_DB  ")
if run_flow_shim "$TD/run-gg-trim.out" root-run govgraph-secrets staging --overwrite <"$F15g"; then
  ok "padded DATABASE_URL accepted (edges trimmed)"
else
  bad "padded DATABASE_URL rejected"; cat "$TD/run-gg-trim.out"; exit 1
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/staging/app \
  | jq -e --arg db "$GG_DB" '.data.data.DATABASE_URL == $db' >/dev/null \
  && ok "stored DATABASE_URL is exactly the trimmed value"

echo "== 15h. the skip path verifies the stored data (a wrong key set is reported, not rubber-stamped)"
BAO_TOKEN="$RT" bao kv put secret/apps/govgraph/staging/app DATABASE_URL="$GG_DB" CRON_SECRETT=typo >/dev/null
F15h=$(feed_govgraph "$GG_DB")
run_flow "$TD/run-gg-skipbad.out" root-run govgraph-secrets staging <"$F15h" || true
if grep -q "does not hold exactly DATABASE_URL + a 64-hex CRON_SECRET" "$TD/run-gg-skipbad.out"; then
  ok "skip path reports the wrong key set instead of printing success"
else
  bad "skip path did not verify the stored data"; cat "$TD/run-gg-skipbad.out"
fi
if grep -q "govgraph-secrets setup complete (staging)" "$TD/run-gg-skipbad.out"; then
  bad "skip path claimed success on a malformed object"
else
  ok "malformed-object run did not complete"
fi
F15h2=$(feed_govgraph "$GG_DB")
if run_flow "$TD/run-gg-skipfix.out" root-run govgraph-secrets staging --overwrite <"$F15h2"; then
  ok "--overwrite repairs the malformed app object"
else
  bad "--overwrite repair failed"; cat "$TD/run-gg-skipfix.out"; exit 1
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/staging/app \
  | jq -e '.data.data | (keys | sort == ["CRON_SECRET","DATABASE_URL"]) and (.CRON_SECRET | test("^[0-9a-f]{64}$"))' >/dev/null \
  && ok "repaired object holds exactly DATABASE_URL + a 64-hex CRON_SECRET"

echo "== 15i. split rotation: --overwrite-cloudflare keeps CRON_SECRET, --overwrite-app regenerates it"
GG_DB2='postgres://ggtest2:throwaway2@127.0.0.1:5432/postgres'
GG_ZONE2='a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2'
GG_TOKEN2='cf-api-token-throwaway-2'
PROD_CRON_1="$(BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/prod/app | jq -r .data.data.CRON_SECRET)"
PROD_APP_V0="$(BAO_TOKEN="$RT" bao read -format=json secret/metadata/apps/govgraph/prod/app | jq -r .data.current_version)"
PROD_CF_V0="$(BAO_TOKEN="$RT" bao read -format=json secret/metadata/apps/govgraph/prod/cloudflare | jq -r .data.current_version)"
# --overwrite-cloudflare prompts for the CF values ONLY (no DATABASE_URL is read or shipped)
F15i=$(feed_govgraph "$GG_ZONE2" "$GG_TOKEN2")
if run_flow_shim "$TD/run-gg-ovcf.out" root-run govgraph-secrets prod --overwrite-cloudflare <"$F15i"; then
  ok "--overwrite-cloudflare exited 0"
else
  bad "--overwrite-cloudflare failed"; cat "$TD/run-gg-ovcf.out"; exit 1
fi
if grep -q "DATABASE_URL must" "$TD/run-gg-ovcf.out"; then
  bad "--overwrite-cloudflare READ A DATABASE_URL (a prompt would have eaten the zone answer and failed validation)"
else
  ok "--overwrite-cloudflare never reads a DATABASE_URL (exit 0 with only the two CF answers fed proves it)"
fi
PROD_CRON_2="$(BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/prod/app | jq -r .data.data.CRON_SECRET)"
PROD_APP_V1="$(BAO_TOKEN="$RT" bao read -format=json secret/metadata/apps/govgraph/prod/app | jq -r .data.current_version)"
PROD_CF_V1="$(BAO_TOKEN="$RT" bao read -format=json secret/metadata/apps/govgraph/prod/cloudflare | jq -r .data.current_version)"
if [[ "$PROD_CRON_2" == "$PROD_CRON_1" ]]; then
  ok "--overwrite-cloudflare kept CRON_SECRET byte-for-byte (web and refresh stay in agreement)"
else
  bad "--overwrite-cloudflare REGENERATED CRON_SECRET"
fi
if [[ "$PROD_APP_V1" == "$PROD_APP_V0" ]]; then
  ok "--overwrite-cloudflare did not touch the app object (version unchanged)"
else
  bad "--overwrite-cloudflare bumped the app object version"
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/prod/cloudflare \
  | jq -e --arg z "$GG_ZONE2" --arg t "$GG_TOKEN2" '.data.data | .CF_ZONE_ID == $z and .CF_API_TOKEN == $t' >/dev/null \
  && ok "--overwrite-cloudflare stored the new CF values"
if [[ "$PROD_CF_V1" != "$PROD_CF_V0" ]]; then
  ok "--overwrite-cloudflare rewrote the cloudflare object (version bumped)"
else
  bad "--overwrite-cloudflare did not rewrite the cloudflare object"
fi
# --overwrite-app prompts for DATABASE_URL ONLY (no CF value is read or shipped)
F15i2=$(feed_govgraph "$GG_DB2")
if run_flow_shim "$TD/run-gg-ovapp.out" root-run govgraph-secrets prod --overwrite-app <"$F15i2"; then
  ok "--overwrite-app exited 0"
else
  bad "--overwrite-app failed"; cat "$TD/run-gg-ovapp.out"; exit 1
fi
if grep -qE "CF_ZONE_ID must|CF_API_TOKEN must" "$TD/run-gg-ovapp.out"; then
  bad "--overwrite-app READ CF VALUES (a prompt would have eaten the answer or hit EOF and failed validation)"
else
  ok "--overwrite-app never reads CF values (exit 0 with only DATABASE_URL fed proves it)"
fi
PROD_CRON_3="$(BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/prod/app | jq -r .data.data.CRON_SECRET)"
PROD_APP_V2="$(BAO_TOKEN="$RT" bao read -format=json secret/metadata/apps/govgraph/prod/app | jq -r .data.current_version)"
PROD_CF_V2="$(BAO_TOKEN="$RT" bao read -format=json secret/metadata/apps/govgraph/prod/cloudflare | jq -r .data.current_version)"
if [[ "$PROD_CRON_3" =~ ^[0-9a-f]{64}$ && "$PROD_CRON_3" != "$PROD_CRON_2" ]]; then
  ok "--overwrite-app regenerated CRON_SECRET (still 64 hex)"
else
  bad "--overwrite-app did not regenerate CRON_SECRET"
fi
if [[ "$PROD_APP_V2" != "$PROD_APP_V1" ]]; then
  ok "--overwrite-app rewrote the app object (version bumped)"
else
  bad "--overwrite-app did not rewrite the app object"
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/prod/app \
  | jq -e --arg db "$GG_DB2" '.data.data.DATABASE_URL == $db' >/dev/null \
  && ok "--overwrite-app stored the new DATABASE_URL"
if [[ "$PROD_CF_V2" == "$PROD_CF_V1" ]]; then
  ok "--overwrite-app left the cloudflare object untouched (version unchanged)"
else
  bad "--overwrite-app bumped the cloudflare object version"
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/prod/cloudflare \
  | jq -e --arg z "$GG_ZONE2" --arg t "$GG_TOKEN2" '.data.data | .CF_ZONE_ID == $z and .CF_API_TOKEN == $t' >/dev/null \
  && ok "--overwrite-app kept the new CF values (still readable, unchanged)"

echo "== 15j. split-flag misuse dies before minting"
if run_flow "$TD/run-gg-flag1.out" root-run govgraph-secrets prod --overwrite --overwrite-app </dev/null; then
  bad "--overwrite + --overwrite-app accepted together"
else
  ok "--overwrite + --overwrite-app refused"
fi
if grep -q "exactly one of --overwrite, --overwrite-app, --overwrite-cloudflare" "$TD/run-gg-flag1.out"; then
  ok "the combination error names all three flags"
else
  bad "combination error missing"; cat "$TD/run-gg-flag1.out"
fi
if run_flow "$TD/run-gg-flag2.out" root-run govgraph-secrets staging --overwrite-cloudflare </dev/null; then
  bad "--overwrite-cloudflare accepted on staging"
else
  ok "--overwrite-cloudflare refused on staging"
fi
if grep -q "staging writes no cloudflare object" "$TD/run-gg-flag2.out"; then
  ok "the staging error explains which flag to use instead"
else
  bad "staging cloudflare error missing"; cat "$TD/run-gg-flag2.out"
fi
if run_flow "$TD/run-gg-flag3.out" root-run govgraph-probes --overwrite-app </dev/null; then
  bad "--overwrite-app accepted on govgraph-probes"
else
  ok "--overwrite-app refused outside govgraph-secrets"
fi
if grep -q "govgraph-secrets only" "$TD/run-gg-flag3.out"; then
  ok "the misuse error names the allowed mode"
else
  bad "misuse error missing"; cat "$TD/run-gg-flag3.out"
fi

echo "== 15k. root-run -- env sees no share (the payload env var is unset on the remote side)"
# The shares ride the ssh stdin payload, but the remote side used to keep
# BREAKGLASS_PAYLOAD exported for the whole session, so `root-run -- <cmd>` and every
# child inherited them. A plain `root-run -- env` must print neither share nor the var.
SHARE2="$(jq -r '.unseal_keys_b64[1]' "$TD/init.json")"
F15k=$(feed_shares)
if run_flow "$TD/run-env.out" root-run -- env <"$F15k"; then
  ok "root-run -- env exited 0"
else
  bad "root-run -- env failed"; cat "$TD/run-env.out"; exit 1
fi
if grep -q "^PATH=" "$TD/run-env.out"; then
  ok "env output captured (positive control)"
else
  bad "env output missing - the leak checks are vacuous"; cat "$TD/run-env.out"
fi
if grep -qF "$SHARE1" "$TD/run-env.out" || grep -qF "$SHARE2" "$TD/run-env.out"; then
  bad "AN UNSEAL SHARE LEAKED INTO root-run -- env OUTPUT"
else
  ok "neither unseal share appears in the child's environment dump"
fi
if grep -q "BREAKGLASS_PAYLOAD" "$TD/run-env.out"; then
  bad "BREAKGLASS_PAYLOAD STILL EXPORTED INTO THE root-run -- CHILD"
else
  ok "the payload variable is unset before any child runs"
fi
# The remote bash -s itself: the payload must never be in its EXEC-TIME environment
# (unsetting after exec does not rewrite /proc/<pid>/environ; on sectools that block is
# readable for the whole session). `ps eww` prints that original environment block for
# every process this user owns, so the remote shell is covered however it was spawned.
F15k2=$(feed_shares)
if run_flow "$TD/run-psenv.out" root-run -- ps eww -o 'command=' <"$F15k2"; then
  ok "root-run -- ps eww (process environments) exited 0"
else
  bad "root-run -- ps eww failed"; cat "$TD/run-psenv.out"; exit 1
fi
if grep -q "PATH=" "$TD/run-psenv.out"; then
  ok "process environments were captured (positive control)"
else
  bad "ps eww output missing - the environ check is vacuous"; cat "$TD/run-psenv.out"
fi
if grep -qF "$SHARE1" "$TD/run-psenv.out" || grep -qF "$SHARE2" "$TD/run-psenv.out" || grep -q "BREAKGLASS_PAYLOAD" "$TD/run-psenv.out"; then
  bad "THE PAYLOAD IS IN SOME PROCESS'S EXEC-TIME ENVIRONMENT"
else
  ok "no share or payload variable in any process's exec-time environment"
fi
unset SHARE2

echo "== 15l. --overwrite-app with no cloudflare object refuses BEFORE writing anything"
# Precondition check up front: the run would have to write the missing cloudflare object
# but carries no CF values, so nothing at all is written (the app object is not rotated).
BAO_TOKEN="$RT" bao kv metadata delete secret/apps/govgraph/prod/cloudflare >/dev/null
PROD_CRON_A="$(BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/prod/app | jq -r .data.data.CRON_SECRET)"
PROD_APP_VA="$(BAO_TOKEN="$RT" bao read -format=json secret/metadata/apps/govgraph/prod/app | jq -r .data.current_version)"
F15l=$(feed_govgraph "$GG_DB2")
if run_flow "$TD/run-gg-atomic.out" root-run govgraph-secrets prod --overwrite-app <"$F15l"; then
  bad "--overwrite-app succeeded with no cloudflare object (should have refused first)"
else
  ok "refused before any write (nonzero exit)"
fi
if grep -q "carries no CF values" "$TD/run-gg-atomic.out"; then
  ok "the refusal explains the missing CF values and the flags that create the object"
else
  bad "refusal message missing"; cat "$TD/run-gg-atomic.out"
fi
PROD_CRON_B="$(BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/prod/app | jq -r .data.data.CRON_SECRET)"
PROD_APP_VB="$(BAO_TOKEN="$RT" bao read -format=json secret/metadata/apps/govgraph/prod/app | jq -r .data.current_version)"
if [[ "$PROD_CRON_B" == "$PROD_CRON_A" && "$PROD_APP_VB" == "$PROD_APP_VA" ]]; then
  ok "the app object is untouched (CRON_SECRET and version unchanged - everything or nothing)"
else
  bad "THE APP OBJECT WAS ROTATED BEFORE THE FAILURE"
fi
# Restore the cloudflare object with a plain no-flag run (app skip path, CF created).
F15l2=$(feed_govgraph "$GG_DB" "$GG_ZONE2" "$GG_TOKEN2")
if run_flow "$TD/run-gg-restore.out" root-run govgraph-secrets prod <"$F15l2"; then
  ok "a no-flag run recreates the cloudflare object"
else
  bad "the restore run failed"; cat "$TD/run-gg-restore.out"; exit 1
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/apps/govgraph/prod/cloudflare \
  | jq -e --arg z "$GG_ZONE2" --arg t "$GG_TOKEN2" '.data.data | .CF_ZONE_ID == $z and .CF_API_TOKEN == $t' >/dev/null \
  && ok "cloudflare object restored with the expected values"
unset RT GG_CRON_1 GG_CRON_2 GG_CRON_3 GG_DB GG_BAD_PORT GG_ZONE GG_TOKEN \
  GG_DB_SLASH GG_DB_SPACE GG_DB2 GG_ZONE2 GG_TOKEN2 PROD_CRON_1 PROD_CRON_2 PROD_CRON_3 \
  PROD_APP_V0 PROD_APP_V1 PROD_APP_V2 PROD_CF_V0 PROD_CF_V1 PROD_CF_V2 \
  PROD_CRON_A PROD_CRON_B PROD_APP_VA PROD_APP_VB

echo "== 16. root-run govgraph-probes: PATCH into the shared probe object"
GG_PS_APEX='https://govgraph.example/'
GG_PS_STAGING='https://govgraph-staging.example/'
GG_PS_APEX2='https://govgraph-2.example/'
GG_PS_STAGING2='https://govgraph-staging-2.example/'
feed_ggprobes() {  # $1/$2 = the two hidden prompt answers (defaults to the first pair)
  local f; f=$(mktemp "$TD/answers.XXXXXX")
  jq -r '.unseal_keys_b64[0,1]' "$TD/init.json" >"$f"
  printf '%s\n' "${1:-$GG_PS_APEX}" "${2:-$GG_PS_STAGING}" >>"$f"
  echo "$f"
}

echo "== 16a. a probe URL without a trailing slash dies before minting"
F16a=$(feed_ggprobes 'https://govgraph.example' "$GG_PS_STAGING")
if run_flow "$TD/run-ggp-slash.out" root-run govgraph-probes <"$F16a"; then
  bad "URL without a trailing slash accepted"
else
  ok "URL without a trailing slash rejected (nonzero exit)"
fi
if grep -q "must end in a slash" "$TD/run-ggp-slash.out"; then
  ok "missing-slash error names the required slash"
else
  bad "missing-slash error missing"; cat "$TD/run-ggp-slash.out"
fi
if grep -q "minting the root token" "$TD/run-ggp-slash.out"; then
  bad "missing-slash run minted a root token (should die locally first)"
else
  ok "missing-slash run died before minting"
fi

echo "== 16b. govgraph-probes PATCHes the object public-site-probes wrote: all four keys, public keys untouched"
RT="$(jq -r .root_token "$TD/init.json")"
F16b=$(feed_ggprobes)
if run_flow_shim "$TD/run-ggp2.out" root-run govgraph-probes <"$F16b"; then
  ok "root-run govgraph-probes exited 0"
else
  bad "root-run govgraph-probes failed"; cat "$TD/run-ggp2.out"; exit 1
fi
if grep -q "stored (govgraph apex ${#GG_PS_APEX} chars, staging ${#GG_PS_STAGING} chars; apex_url/staging_url untouched)" "$TD/run-ggp2.out"; then
  ok "prints stored (N chars) + untouched note only"
else
  bad "govgraph-probes stored line missing"; cat "$TD/run-ggp2.out"
fi
if grep -q "govgraph-probes setup complete" "$TD/run-ggp2.out"; then ok "govgraph-probes run completed"; else bad "govgraph-probes completion line missing"; fi
if grep -q "revocation verified" "$TD/run-ggp2.out"; then ok "govgraph-probes run revoked its token"; else bad "govgraph-probes revocation missing"; fi
BAO_TOKEN="$RT" bao read -format=json secret/data/monitoring/public-site-probes \
  | jq -e --arg a "$PS_APEX" --arg s "$PS_STAGING" --arg ga "$GG_PS_APEX" --arg gs "$GG_PS_STAGING" \
    '.data.data | ((keys | sort) == ["apex_url","govgraph_apex_url","govgraph_staging_url","staging_url"])
     and .apex_url == $a and .staging_url == $s
     and .govgraph_apex_url == $ga and .govgraph_staging_url == $gs' >/dev/null \
  && ok "all four probe keys present; public-site URLs unchanged, govgraph URLs stored"
if grep -qF "$GG_PS_APEX" "$TD/ssh-argv.log" || grep -qF "$GG_PS_STAGING" "$TD/ssh-argv.log"; then
  bad "A GOVGRAPH PROBE URL APPEARED IN THE SSH BOUNDARY'S ARGV"
else
  ok "govgraph probe URLs never cross the ssh boundary on argv"
fi
if grep -qF "$GG_PS_APEX" "$TD/run-ggp2.out" || grep -qF "$GG_PS_STAGING" "$TD/run-ggp2.out"; then
  bad "A GOVGRAPH PROBE URL WAS PRINTED INTO THE TRANSCRIPT"
else
  ok "govgraph probe URLs never printed"
fi
if grep -qF "$GG_PS_APEX" "$TD/jq-argv.log" || grep -qF "$GG_PS_STAGING" "$TD/jq-argv.log"; then
  bad "A GOVGRAPH PROBE URL APPEARED IN A LOCAL/REMOTE JQ ARGV"
else
  ok "govgraph probe URLs never ride a local/remote jq argv"
fi

echo "== 16c. re-run refuses without --overwrite; --overwrite replaces just the govgraph keys"
F16c=$(feed_ggprobes)
run_flow_shim "$TD/run-ggp3.out" root-run govgraph-probes <"$F16c" || true
if grep -q "already exist" "$TD/run-ggp3.out"; then
  ok "second govgraph-probes run refuses the existing keys"
else
  bad "second govgraph-probes run did not refuse"; cat "$TD/run-ggp3.out"
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/monitoring/public-site-probes \
  | jq -e --arg ga "$GG_PS_APEX" --arg gs "$GG_PS_STAGING" --arg a "$PS_APEX" --arg s "$PS_STAGING" \
    '.data.data | .govgraph_apex_url == $ga and .govgraph_staging_url == $gs and .apex_url == $a and .staging_url == $s' >/dev/null \
  && ok "the refused run changed nothing (all four values intact)"
F16d=$(feed_ggprobes "$GG_PS_APEX2" "$GG_PS_STAGING2")
if run_flow_shim "$TD/run-ggp4.out" root-run govgraph-probes --overwrite <"$F16d"; then
  ok "govgraph-probes --overwrite exited 0"
else
  bad "govgraph-probes --overwrite failed"; cat "$TD/run-ggp4.out"; exit 1
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/monitoring/public-site-probes \
  | jq -e --arg ga "$GG_PS_APEX2" --arg gs "$GG_PS_STAGING2" --arg a "$PS_APEX" --arg s "$PS_STAGING" \
    '.data.data | ((keys | sort) == ["apex_url","govgraph_apex_url","govgraph_staging_url","staging_url"])
     and .govgraph_apex_url == $ga and .govgraph_staging_url == $gs
     and .apex_url == $a and .staging_url == $s' >/dev/null \
  && ok "--overwrite replaced only the govgraph keys; public-site URLs still intact"

echo "== 16d. public-site-probes --overwrite afterwards KEEPS the govgraph keys (patch, not put)"
F16e=$(feed_publicsite)
if run_flow_shim "$TD/run-ps3.out" root-run public-site-probes --overwrite <"$F16e"; then
  ok "public-site-probes --overwrite exited 0"
else
  bad "public-site-probes --overwrite failed"; cat "$TD/run-ps3.out"; exit 1
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/monitoring/public-site-probes \
  | jq -e --arg a "$PS_APEX" --arg s "$PS_STAGING" --arg ga "$GG_PS_APEX2" --arg gs "$GG_PS_STAGING2" \
    '.data.data | ((keys | sort) == ["apex_url","govgraph_apex_url","govgraph_staging_url","staging_url"])
     and .apex_url == $a and .staging_url == $s
     and .govgraph_apex_url == $ga and .govgraph_staging_url == $gs' >/dev/null \
  && ok "public-site-probes --overwrite kept both govgraph keys (the modes cannot clobber each other)"
if grep -q "public-site-probes setup complete" "$TD/run-ps3.out"; then ok "public-site-probes run completed"; else bad "public-site-probes completion line missing"; fi
if grep -q "revocation verified" "$TD/run-ps3.out"; then ok "public-site-probes overwrite run revoked its token"; else bad "public-site-probes overwrite revocation missing"; fi
if grep -qF "$PS_APEX" "$TD/jq-argv.log" || grep -qF "$PS_STAGING" "$TD/jq-argv.log" \
  || grep -qF "$GG_PS_APEX2" "$TD/jq-argv.log" || grep -qF "$GG_PS_STAGING2" "$TD/jq-argv.log"; then
  bad "A PROBE URL APPEARED IN A LOCAL/REMOTE JQ ARGV"
else
  ok "no probe URL rides a local/remote jq argv (either mode, either side)"
fi

echo "== 16e. a stray key is refused without --overwrite; with it the canonical write DROPS it"
# Raw-write a stray key past both modes: neither may write over it silently, but
# --overwrite must also be a complete argv-free way to remove it (canonical write).
BAO_TOKEN="$RT" bao kv put secret/monitoring/public-site-probes \
  apex_url="$PS_APEX" staging_url="$PS_STAGING" \
  govgraph_apex_url="$GG_PS_APEX2" govgraph_staging_url="$GG_PS_STAGING2" \
  stray_key=stray-value >/dev/null
PSPV_S1="$(BAO_TOKEN="$RT" bao read -format=json secret/metadata/monitoring/public-site-probes | jq -r .data.current_version)"
F16e=$(feed_ggprobes)
run_flow "$TD/run-ggp-stray.out" root-run govgraph-probes <"$F16e" || true
if grep -q "keys other than the four probe keys" "$TD/run-ggp-stray.out"; then
  ok "govgraph-probes refuses the stray key before writing"
else
  bad "govgraph-probes did not refuse the stray key"; cat "$TD/run-ggp-stray.out"
fi
F16e3=$(feed_publicsite)
run_flow "$TD/run-ps-stray.out" root-run public-site-probes <"$F16e3" || true
if grep -q "keys other than the four probe keys" "$TD/run-ps-stray.out"; then
  ok "public-site-probes also refuses the stray key before writing"
else
  bad "public-site-probes did not refuse the stray key"; cat "$TD/run-ps-stray.out"
fi
PSPV_S2="$(BAO_TOKEN="$RT" bao read -format=json secret/metadata/monitoring/public-site-probes | jq -r .data.current_version)"
if [[ "$PSPV_S2" == "$PSPV_S1" ]]; then
  ok "no version bump: nothing was written while the stray key was present"
else
  bad "THE OBJECT WAS WRITTEN DESPITE THE STRAY KEY"
fi
F16e2=$(feed_ggprobes)
if run_flow "$TD/run-ggp-stray2.out" root-run govgraph-probes --overwrite <"$F16e2"; then
  ok "govgraph-probes --overwrite writes the canonical keys and drops the stray one"
else
  bad "govgraph-probes --overwrite failed on the stray-key object"; cat "$TD/run-ggp-stray2.out"; exit 1
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/monitoring/public-site-probes \
  | jq -e --arg a "$PS_APEX" --arg s "$PS_STAGING" --arg ga "$GG_PS_APEX" --arg gs "$GG_PS_STAGING" \
    '.data.data | ((keys | sort) == ["apex_url","govgraph_apex_url","govgraph_staging_url","staging_url"])
     and .apex_url == $a and .staging_url == $s
     and .govgraph_apex_url == $ga and .govgraph_staging_url == $gs' >/dev/null \
  && ok "the stray key is gone and all four canonical keys hold the right values (no raw argv write needed)"
# public-site-probes --overwrite must drop a stray key the same way.
BAO_TOKEN="$RT" bao kv put secret/monitoring/public-site-probes \
  apex_url="$PS_APEX" staging_url="$PS_STAGING" \
  govgraph_apex_url="$GG_PS_APEX" govgraph_staging_url="$GG_PS_STAGING" \
  stray_key=stray-value >/dev/null
F16e5=$(feed_publicsite)
if run_flow "$TD/run-ps-stray2.out" root-run public-site-probes --overwrite <"$F16e5"; then
  ok "public-site-probes --overwrite writes the canonical keys and drops the stray one"
else
  bad "public-site-probes --overwrite failed on the stray-key object"; cat "$TD/run-ps-stray2.out"; exit 1
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/monitoring/public-site-probes \
  | jq -e --arg a "$PS_APEX" --arg s "$PS_STAGING" --arg ga "$GG_PS_APEX" --arg gs "$GG_PS_STAGING" \
    '.data.data | ((keys | sort) == ["apex_url","govgraph_apex_url","govgraph_staging_url","staging_url"])
     and .apex_url == $a and .staging_url == $s
     and .govgraph_apex_url == $ga and .govgraph_staging_url == $gs' >/dev/null \
  && ok "both modes can fully repair the shared object argv-free"
F16e4=$(feed_ggprobes)
run_flow "$TD/run-ggp-stray3.out" root-run govgraph-probes <"$F16e4" || true
if grep -q "already exist" "$TD/run-ggp-stray3.out"; then
  ok "with the stray key gone, the skip path works again"
else
  bad "skip path still failing after the repair"; cat "$TD/run-ggp-stray3.out"
fi

echo "== 16f. an empty stored govgraph URL is refused on the keep path; --overwrite repairs a lone govgraph key"
# empty value: both govgraph keys exist but govgraph_staging_url is empty (a hand edit).
# The keep path must refuse it - an empty target would silently kill that probe.
BAO_TOKEN="$RT" bao kv put secret/monitoring/public-site-probes \
  apex_url="$PS_APEX" staging_url="$PS_STAGING" \
  govgraph_apex_url="$GG_PS_APEX2" govgraph_staging_url="" >/dev/null
F16f0=$(feed_ggprobes)
run_flow "$TD/run-ggp-empty.out" root-run govgraph-probes <"$F16f0" || true
if grep -q "must both be non-empty" "$TD/run-ggp-empty.out"; then
  ok "an empty govgraph_staging_url is refused on the keep path (no third read of the secret)"
else
  bad "empty govgraph_staging_url accepted"; cat "$TD/run-ggp-empty.out"
fi
F16f0b=$(feed_ggprobes)
if run_flow "$TD/run-ggp-emptyfix.out" root-run govgraph-probes --overwrite <"$F16f0b"; then
  ok "--overwrite repairs the empty value"
else
  bad "--overwrite repair of the empty value failed"; cat "$TD/run-ggp-emptyfix.out"; exit 1
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/monitoring/public-site-probes \
  | jq -e --arg ga "$GG_PS_APEX" --arg gs "$GG_PS_STAGING" \
    '.data.data | .govgraph_apex_url == $ga and .govgraph_staging_url == $gs' >/dev/null \
  && ok "both govgraph URLs are non-empty again"
# lone govgraph key: govgraph_apex_url without its pair
BAO_TOKEN="$RT" bao kv put secret/monitoring/public-site-probes \
  apex_url="$PS_APEX" staging_url="$PS_STAGING" govgraph_apex_url="$GG_PS_APEX" >/dev/null
F16f=$(feed_ggprobes)
run_flow "$TD/run-ggp-lone.out" root-run govgraph-probes <"$F16f" || true
if grep -q "only one of the two govgraph keys" "$TD/run-ggp-lone.out"; then
  ok "a lone govgraph key is refused without --overwrite"
else
  bad "lone govgraph key not refused"; cat "$TD/run-ggp-lone.out"
fi
F16f2=$(feed_ggprobes)
if run_flow "$TD/run-ggp-lonefix.out" root-run govgraph-probes --overwrite <"$F16f2"; then
  ok "--overwrite repairs the lone govgraph key"
else
  bad "--overwrite repair of the lone key failed"; cat "$TD/run-ggp-lonefix.out"; exit 1
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/monitoring/public-site-probes \
  | jq -e --arg a "$PS_APEX" --arg s "$PS_STAGING" --arg ga "$GG_PS_APEX" --arg gs "$GG_PS_STAGING" \
    '.data.data | ((keys | sort) == ["apex_url","govgraph_apex_url","govgraph_staging_url","staging_url"])
     and .apex_url == $a and .staging_url == $s
     and .govgraph_apex_url == $ga and .govgraph_staging_url == $gs' >/dev/null \
  && ok "repaired object holds the canonical four keys with the base pair intact"
if grep -q "PATCHing secret/monitoring/public-site-probes (govgraph_apex_url + govgraph_staging_url; apex_url/staging_url untouched; cas " "$TD/run-ggp-lonefix.out"; then
  ok "the PATCH line names the check-and-set version it read"
else
  bad "the PATCH line does not name a cas version"; cat "$TD/run-ggp-lonefix.out"
fi
# missing base pair: only the govgraph keys -> govgraph-probes refuses (it cannot write
# the base pair); public-site-probes --overwrite rebuilds it and carries the pair over
BAO_TOKEN="$RT" bao kv put secret/monitoring/public-site-probes \
  govgraph_apex_url="$GG_PS_APEX" govgraph_staging_url="$GG_PS_STAGING" >/dev/null
F16f3=$(feed_ggprobes)
run_flow "$TD/run-ggp-nobase.out" root-run govgraph-probes <"$F16f3" || true
if grep -q "lacks apex_url/staging_url" "$TD/run-ggp-nobase.out"; then
  ok "govgraph-probes refuses an object with no base pair (it cannot write those keys)"
else
  bad "missing-base-pair object not refused"; cat "$TD/run-ggp-nobase.out"
fi
F16f4=$(feed_publicsite)
if run_flow "$TD/run-ps-repair.out" root-run public-site-probes --overwrite <"$F16f4"; then
  ok "public-site-probes --overwrite repairs the missing base pair"
else
  bad "public-site-probes --overwrite repair failed"; cat "$TD/run-ps-repair.out"; exit 1
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/monitoring/public-site-probes \
  | jq -e --arg a "$PS_APEX" --arg s "$PS_STAGING" --arg ga "$GG_PS_APEX" --arg gs "$GG_PS_STAGING" \
    '.data.data | ((keys | sort) == ["apex_url","govgraph_apex_url","govgraph_staging_url","staging_url"])
     and .apex_url == $a and .staging_url == $s
     and .govgraph_apex_url == $ga and .govgraph_staging_url == $gs' >/dev/null \
  && ok "repaired object: base pair restored, govgraph pair carried over untouched"

echo "== 16g. the server enforces check-and-set (what makes the cas on every write meaningful)"
PSPV_C="$(BAO_TOKEN="$RT" bao read -format=json secret/metadata/monitoring/public-site-probes | jq -r .data.current_version)"
STALE=$((PSPV_C - 1))
CASHTTP="$(curl -s -o /dev/null -w '%{http_code}' -H "X-Vault-Token: $RT" \
  -d "{\"options\":{\"cas\":$STALE},\"data\":{\"apex_url\":\"x\",\"staging_url\":\"y\",\"govgraph_apex_url\":\"z\",\"govgraph_staging_url\":\"w\"}}" \
  "$ADDR/v1/secret/data/monitoring/public-site-probes")"
if [[ "$CASHTTP" == "400" ]]; then
  ok "a stale-cas write is rejected by the server (HTTP 400), so a racing writer cannot be clobbered"
else
  bad "stale-cas write returned HTTP $CASHTTP (expected 400)"
fi

echo "== 16h. a soft-deleted latest version (data 404, metadata 200): refused without --overwrite, rebuilt with it"
# `bao kv delete` soft-deletes the data of the latest version; the metadata path still
# answers 200. Without --overwrite the run must refuse (no silent empty success);
# with it public-site-probes writes the canonical object again at the current version.
BAO_TOKEN="$RT" bao kv delete secret/monitoring/public-site-probes >/dev/null
F16h0=$(feed_publicsite)
if run_flow "$TD/run-ps-sdrefuse.out" root-run public-site-probes <"$F16h0"; then
  bad "a soft-deleted object reported success without --overwrite"
else
  ok "soft-deleted object refused without --overwrite (nonzero exit)"
fi
if grep -q "soft-deleted" "$TD/run-ps-sdrefuse.out"; then
  ok "the refusal names the soft delete and --overwrite"
else
  bad "soft-delete refusal message missing"; cat "$TD/run-ps-sdrefuse.out"
fi
if grep -q "public-site-probes setup complete" "$TD/run-ps-sdrefuse.out"; then
  bad "THE REFUSED RUN STILL CLAIMED COMPLETION"
else
  ok "no success line on the refused run"
fi
F16h=$(feed_publicsite)
if run_flow "$TD/run-ps-undelete.out" root-run public-site-probes --overwrite <"$F16h"; then
  ok "public-site-probes --overwrite rebuilt the soft-deleted object"
else
  bad "rebuild of the soft-deleted object failed"; cat "$TD/run-ps-undelete.out"; exit 1
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/monitoring/public-site-probes \
  | jq -e --arg a "$PS_APEX" --arg s "$PS_STAGING" \
    '.data.data | ((keys | sort) == ["apex_url","staging_url"]) and .apex_url == $a and .staging_url == $s' >/dev/null \
  && ok "the base pair is back (the govgraph pair is re-added by govgraph-probes)"
F16h2=$(feed_ggprobes)
if run_flow "$TD/run-ggp-undelete.out" root-run govgraph-probes <"$F16h2"; then
  ok "govgraph-probes re-adds the pair afterwards"
else
  bad "govgraph-probes failed after the rebuild"; cat "$TD/run-ggp-undelete.out"; exit 1
fi
BAO_TOKEN="$RT" bao read -format=json secret/data/monitoring/public-site-probes \
  | jq -e --arg a "$PS_APEX" --arg s "$PS_STAGING" --arg ga "$GG_PS_APEX" --arg gs "$GG_PS_STAGING" \
    '.data.data | ((keys | sort) == ["apex_url","govgraph_apex_url","govgraph_staging_url","staging_url"])
     and .apex_url == $a and .staging_url == $s
     and .govgraph_apex_url == $ga and .govgraph_staging_url == $gs' >/dev/null \
  && ok "all four keys restored after the soft-delete repair"
unset RT GG_PS_APEX GG_PS_STAGING GG_PS_APEX2 GG_PS_STAGING2 PSPV_S1 PSPV_S2 PSPV_C STALE CASHTTP

echo ""
echo "result: $PASS passed, $FAIL failed"
if [[ "$FAIL" != 0 ]]; then exit 1; fi
if [[ "$CLEANUP" == keep ]]; then echo "temp dir kept: $TD"; fi
exit 0
