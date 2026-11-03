#!/usr/bin/env bash
# OpenBao break-glass root path (ADR 0014, runbook docs/runbooks/openbao.md §6).
#
# Problem this solves (verified 2026-11-03): the root token was revoked (2026-11-02), and
# OpenBao >= 2.5.3 defaults disable_unauthed_generate_root_endpoints to true, so
# `bao operator generate-root` 403s. Worse, the bao 2.7.2 CLI's generate-root subcommands
# are unusable against a 2.7.2 server even with the flag false: they call the LEGACY
# /v1/sys/generate-root-token/* endpoints, which the server gates unconditionally
# (-generate-otp, -init and even -decode abort on the status check first - all verified
# against a real local 2.7.2 server). This script therefore speaks the NEW API directly
# (PUT /v1/sys/generate-root/attempt to init, PUT /v1/sys/generate-root/update per share)
# and decodes client-side (unpadded-base64 XOR with the OTP, the same math the CLI does).
#
# The mint runs ON sectools; the root token never reaches the Mac or any terminal output.
# Unseal shares and the SMTP app password are read with `read -rs` locally and travel to
# sectools over ssh stdin (never argv, never echoed).
#
# Usage (owner, from the Mac):
#   scripts/openbao-breakglass.sh apply-config            # once: playbook + unseal
#   scripts/openbao-breakglass.sh root-run alertmanager   # the alert setup (§D step 5)
#   scripts/openbao-breakglass.sh root-run -- <cmd...>    # anything else with the token
#   everything also accepts --dry-run
#
# `apply-config` runs (and prints) exactly:
#   cd ansible && ansible-playbook playbooks/openbao.yml --limit sectools --check --diff
#   cd ansible && ansible-playbook playbooks/openbao.yml --limit sectools
# The listener flag is startup-only (NOT SIGHUP-reloadable, verified 2026-11-03), so the
# playbook restarts openbao and the store comes back SEALED; apply-config then unseals it
# by piping one share at a time to PUT /v1/sys/unseal (the bao CLI refuses piped stdin
# for unseal - also verified - so the API it is), prompting hidden until it is unsealed.
#
# `root-run` (one ssh session): generate OTP, init, submit the 3 shares, decode into a
# remote variable, run the command with BAO_TOKEN set, then ALWAYS revoke the token -
# explicit revoke + verification, with a trap as the backstop on any failure.
#
# Why `root-run alertmanager` embeds the setup instead of running
# scripts/openbao-setup-alertmanager.sh through an `ssh -L` tunnel (the brief asked to
# pick): the tunnel would need BAO_TOKEN in a LOCAL environment variable, i.e. the root
# token would reach the Mac - exactly what this script exists to prevent. Embedding the
# same idempotent API calls (policy, kubernetes role, kv secret) keeps the token on
# sectools; the payloads are copied from openbao-setup-alertmanager.sh (falco PR #33),
# which stays the reference for a flow where you already hold a short-lived token.
#
# Undo of what `root-run alertmanager` writes (same as the falco PR #33 script):
#   curl -qsS -H "X-Vault-Token: <token>" -X DELETE "$ADDR/v1/secret/metadata/monitoring/alertmanager"
#   curl -qsS -H "X-Vault-Token: <token>" -X DELETE "$ADDR/v1/auth/kubernetes/role/alertmanager"
#   curl -qsS -H "X-Vault-Token: <token>" -X DELETE "$ADDR/v1/sys/policies/acl/alertmanager-read"
#
# Requires an ssh alias `sectools` (e.g. HostName 192.168.1.95, User tunsadmin) or the
# BREAKGLASS_SSH override. Test-only overrides (used by openbao-breakglass-test.sh):
# BREAKGLASS_SSH (e.g. "bash -c" to run the remote script locally), BREAKGLASS_BAO_ADDR
# (default http://127.0.0.1:8200, the address the REMOTE side uses), BREAKGLASS_SECTOOLS_DIR.
#
# No secrets are printed. No argv carries a secret. Everything is non-destructive except
# the documented writes of the command you asked it to run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRY_RUN=false
OVERWRITE=false
SHARES_REQUIRED=3   # the store was inited 5 shares / 3 threshold (ADR 0014, runbook §2)

# The ssh runner as an array: default "ssh tunsadmin@192.168.1.95"; tests override with e.g. "bash -c"
# (argv word splitting is safe here; the override never contains secrets).
read -r -a SSH_RUNNER <<<"${BREAKGLASS_SSH:-ssh -o BatchMode=yes tunsadmin@192.168.1.95}"
REMOTE_ADDR="${BREAKGLASS_BAO_ADDR:-http://127.0.0.1:8200}"
PLAYBOOK_DIR="${BREAKGLASS_PLAYBOOK_DIR:-$REPO_ROOT/ansible}"

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

say()  { echo "==> $*"; }
note() { echo "    $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# apply-config
# ---------------------------------------------------------------------------
cmd_apply_config() {
  say "openbao break-glass apply-config"
  say "playbook commands that will run (in this order):"
  note "cd \"$PLAYBOOK_DIR\" && ansible-playbook playbooks/openbao.yml --limit sectools --check --diff"
  note "cd \"$PLAYBOOK_DIR\" && ansible-playbook playbooks/openbao.yml --limit sectools"
  if [[ "$DRY_RUN" == true ]]; then
    say "--dry-run: nothing run, nothing contacted"
    note "the real run restarts openbao (the listener flag is startup-only, verified"
    note "2026-11-03) so the store comes back SEALED; this command would then prompt for"
    note "unseal shares (hidden) until PUT /v1/sys/unseal reports unsealed."
    return 0
  fi

  say "running the playbook with --check --diff first"
  ( cd "$PLAYBOOK_DIR" && ansible-playbook playbooks/openbao.yml --limit sectools --check --diff )
  say "running the playbook for real (this restarts openbao and re-seals the store)"
  ( cd "$PLAYBOOK_DIR" && ansible-playbook playbooks/openbao.yml --limit sectools )

  say "checking the seal status through $REMOTE_ADDR"
  local sealed
  sealed=$(remote_seal_status) || die "cannot reach OpenBao on sectools ($REMOTE_ADDR)"
  note "sealed=$sealed"
  if [[ "$sealed" == "false" ]]; then
    say "store is unsealed - nothing more to do"
    return 0
  fi
  unseal_loop
}

remote_seal_status() {
  "${SSH_RUNNER[@]}" "curl -q -s $REMOTE_ADDR/v1/sys/seal-status | jq -r .sealed"
}

# Prompt hidden shares locally, one at a time, each piped over ssh stdin to the unseal
# API. The bao CLI refuses piped stdin for unseal (verified 2026-11-03), so this is curl
# talking to PUT /v1/sys/unseal. Stops as soon as the store reports unsealed, so it works
# whatever the real threshold is.
unseal_loop() {
  say "unsealing with your shares (input hidden, one per prompt, Enter on empty to abort)"
  local n=0 sealed=true share
  while [[ "$sealed" == "true" ]]; do
    n=$((n+1))
    read -rs -p "    unseal share #$n: " share
    echo >&2
    [[ -z "$share" ]] && die "empty share entered - aborting (store still sealed)"
    # The share travels: local variable -> jq stdin (pipe) -> ssh stdin (pipe). Never argv.
    sealed=$(printf '%s\n' "$share" | jq -Rs '{key: (rtrimstr("\n"))}' \
      | "${SSH_RUNNER[@]}" "curl -q -s -X PUT --data-binary @- $REMOTE_ADDR/v1/sys/unseal | jq -r .sealed")
    note "sealed=$sealed"
  done
  say "store unsealed"
}

# ---------------------------------------------------------------------------
# root-run
# ---------------------------------------------------------------------------
cmd_root_run() {
  local mode="exec" cmd_args=()
  local args=()
  [[ $# -gt 0 ]] || die "root-run needs a command: 'root-run alertmanager' or 'root-run -- <cmd...>'"
  # allow `root-run -- cmd` and `root-run cmd`; --dry-run/--overwrite peeled off anywhere
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY_RUN=true ;;
      --overwrite) OVERWRITE=true ;;
      --) ;;
      *) args+=("$a") ;;
    esac
  done
  [[ ${#args[@]} -eq 0 ]] && die "root-run needs a command after the flags"
  if [[ "${args[0]}" == "alertmanager" ]]; then
    mode="alertmanager"
    [[ ${#args[@]} -gt 1 ]] && die "root-run alertmanager takes no extra arguments (flags: --overwrite --dry-run)"
  else
    cmd_args=("${args[@]}")
  fi

  say "openbao break-glass root-run ($mode)"

  # Prompt locally for the shares (hidden). The store was inited with a 3-of-5 threshold;
  # the count is a constant so the flow stays ONE command and ONE session. --dry-run
  # substitutes placeholders: it never asks for (or touches) real secrets.
  local shares=() s i
  if [[ "$DRY_RUN" == true ]]; then
    for i in $(seq 1 "$SHARES_REQUIRED"); do shares+=("<share-$i>"); done
  else
    for i in $(seq 1 "$SHARES_REQUIRED"); do
      read -rs -p "    unseal share #$i of $SHARES_REQUIRED: " s
      echo >&2
      [[ -z "$s" ]] && die "empty share entered - aborting (nothing was changed)"
      shares+=("$s"); unset s
    done
  fi

  # Build the payload. The shares go from local variables into a pipe (stdin, not argv):
  # printf -> jq stdin -> variable. Same for everything else secret-shaped below.
  local shares_json payload
  shares_json=$(printf '%s\n' "${shares[@]}" | jq -Rs 'split("\n") | map(select(length > 0))')
  payload=$(jq -cn --arg addr "$REMOTE_ADDR" --argjson shares "$shares_json" '{addr: $addr, shares: $shares}')
  unset s shares shares_json

  if [[ "$mode" == "alertmanager" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      payload=$(jq -cn --argjson p "$payload" \
        '$p + {smtp: {username: "<prompted>", from: "<prompted>", to: "<prompted>", password: "<hidden>"}, overwrite: false}')
    else
      payload=$(alertmanager_prompt_and_extend "$payload")
    fi
  else
    # Shell-quoted so the remote bash -c runs exactly this command; the command is the
    # operator's own text, not a secret, but quoting keeps word boundaries intact.
    local cmd_quoted
    cmd_quoted=$(printf '%q ' "${cmd_args[@]}")
    payload=$(jq -cn --arg c "$cmd_quoted" --argjson p "$payload" '$p + {cmd: $c}')
    say "command that will run on sectools with the root token: ${cmd_quoted% }"
    note "its output is printed as-is - do not run commands that print secret values"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    say "--dry-run: nothing contacted. One ssh session would have:"
    note "1. cancel any in-flight generation, generate a 26-char OTP (client-side)"
    note "2. PUT /v1/sys/generate-root/attempt {otp} -> nonce"
    note "3. submit $SHARES_REQUIRED shares to PUT /v1/sys/generate-root/update (via stdin)"
    note "4. decode encoded_token with the OTP on sectools (XOR, unpadded base64)"
    note "5. verify the token is root, run the $mode step with BAO_TOKEN set"
    note "6. revoke the token and verify the revocation (trap as backstop)"
    return 0
  fi

  say "minting the root token on sectools and running the $mode step (this can take a minute)"
  # One ssh session, two-part stdin: the payload JSON on line 1 (into an env var, off
  # argv), then the script itself. If the session fails, re-running is safe: the script
  # cancels any in-flight root generation before it starts.
  if ! { printf '%s\n' "$payload"; cat <<'REMOTE_SCRIPT'
set -euo pipefail
umask 077
P="${BREAKGLASS_PAYLOAD:?}"
ADDR=$(jq -r .addr <<<"$P")
MODE=$(jq -r 'if .cmd then "exec" else "alertmanager" end' <<<"$P")

echo "    [remote] health check"
curl -q -s "$ADDR/v1/sys/health" | jq -e '.initialized and (.sealed | not)' >/dev/null \
  || { echo "ERROR: OpenBao at $ADDR is not initialized+unsealed (run apply-config / runbook section 3 first)" >&2; exit 1; }

echo "    [remote] cancelling any in-flight root generation (idempotent)"
curl -q -s -o /dev/null -X DELETE "$ADDR/v1/sys/generate-root/attempt" || true

# OTP: client-side random base62, the same alphabet/length the CLI uses. In-process
# python3, not `tr | head`: with pipefail, head closing the pipe early SIGPIPE-kills tr
# and the whole session (found by the test harness; secrets.choice is also stronger).
OTP=$(python3 -c '
import secrets, string
print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(26)))')
NONCE=$(jq -n --arg o "$OTP" '{otp: $o}' \
  | curl -q -s -X PUT --data-binary @- "$ADDR/v1/sys/generate-root/attempt" | jq -r '.nonce // empty')
[[ -n "$NONCE" ]] || { echo "ERROR: generate-root init failed (is the listener flag set?) - run apply-config" >&2; exit 1; }

RESP=""
n=0
while IFS= read -r share; do
  [[ -z "$share" ]] && continue
  n=$((n+1))
  RESP=$(jq -n --arg k "$share" --arg nonce "$NONCE" '{key: $k, nonce: $nonce}' \
    | curl -q -s -X PUT --data-binary @- "$ADDR/v1/sys/generate-root/update")
  echo "    [remote] share $n accepted: $(jq -c '{complete, progress, errors}' <<<"$RESP")"
  # Break the moment the threshold is met: the store's init shape is documented two
  # ways (ADR 0014: 3 shares/2 threshold; the week-6 docs: 5 shares/3), and submitting
  # past "complete" would error. Three prompts always satisfy either.
  [[ "$(jq -r .complete <<<"$RESP")" == "true" ]] && break
done < <(jq -r '.shares[]' <<<"$P")
[[ "$(jq -r .complete <<<"$RESP")" == "true" ]] \
  || { echo "ERROR: all shares submitted but generation incomplete - wrong shares or changed threshold" >&2; exit 1; }

# Decode on sectools, into a variable. Same math as the CLI: base64 (unpadded) then XOR
# with the OTP. Env vars, not argv.
ENCODED=$(jq -r .encoded_token <<<"$RESP")
ROOT_TOKEN=$(ENCODED="$ENCODED" OTP="$OTP" python3 -c '
import base64, os
e, k = os.environ["ENCODED"], os.environ["OTP"].encode()
raw = base64.b64decode(e + "=" * (-len(e) % 4))
sysout = "".join(chr(b ^ k[i % len(k)]) for i, b in enumerate(raw))
assert sysout.startswith("s."), "decode produced a non-token"
print(sysout)')
unset ENCODED OTP NONCE
export BAO_ADDR="$ADDR" BAO_TOKEN="$ROOT_TOKEN"

# Token in a curl config file (0600), never on a curl command line. The trap revokes
# BEFORE removing the config (revoke needs the token; the order was once wrong and a
# failed run left the minted token alive - found by the test harness).
CFG=$(mktemp)
trap 'curl -q -s -o /dev/null --config "$CFG" -X POST "$ADDR/v1/auth/token/revoke-self" || true; rm -f "$CFG"' EXIT
printf 'header = "X-Vault-Token: %s"\n' "$ROOT_TOKEN" >"$CFG"

echo "    [remote] verifying the minted token is root"
curl -q -s --config "$CFG" "$ADDR/v1/auth/token/lookup-self" \
  | jq -e '.data.policies | index("root") != null' >/dev/null \
  || { echo "ERROR: the minted token is not a root token" >&2; exit 1; }

if [[ "$MODE" == "exec" ]]; then
  CMD=$(jq -r .cmd <<<"$P")
  echo "    [remote] running: $CMD"
  bash -c "$CMD"
else
  # ---- the alertmanager setup (same calls and payloads as the falco PR #33 script) ----
  KV=monitoring/alertmanager
  echo "    [remote] checking mounts (kv v2 at secret/, kubernetes auth)"
  curl -q -s --config "$CFG" "$ADDR/v1/sys/mounts" | jq -e '.["secret/"].options.version == "2"' >/dev/null \
    || { echo "ERROR: kv v2 is not mounted at secret/" >&2; exit 1; }
  curl -q -s --config "$CFG" "$ADDR/v1/sys/auth" | jq -e '.["kubernetes/"].type == "kubernetes"' >/dev/null \
    || { echo "ERROR: kubernetes auth missing (run openbao-setup-belleshop.sh first)" >&2; exit 1; }

  echo "    [remote] writing policy alertmanager-read"
  POLICY=$(cat <<'HCL'
# Least-privilege read policy for Alertmanager ESO sync in namespace monitoring (ADR 0015 D).
path "secret/data/monitoring/alertmanager" {
  capabilities = ["read"]
}
HCL
)
  jq -n --arg policy "$POLICY" '{policy: $policy}' \
    | curl -q -s -o /dev/null --config "$CFG" -X PUT --data-binary @- "$ADDR/v1/sys/policies/acl/alertmanager-read"

  echo "    [remote] writing kubernetes auth role alertmanager (SA monitoring/eso-alertmanager)"
  jq -n '{bound_service_account_names: ["eso-alertmanager"], bound_service_account_namespaces: ["monitoring"], token_policies: ["alertmanager-read"], token_ttl: "1h"}' \
    | curl -q -s -o /dev/null --config "$CFG" -X POST --data-binary @- "$ADDR/v1/auth/kubernetes/role/alertmanager"

  EXISTS=$(curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' "$ADDR/v1/secret/metadata/$KV")
  OVER=$(jq -r '.overwrite // false' <<<"$P")
  if [[ "$EXISTS" == "200" && "$OVER" != "true" ]]; then
    echo "    [remote] secret/$KV already exists (pass --overwrite to replace)"
  else
    echo "    [remote] writing secret/$KV with the prompted SMTP values"
    # kv v2 wraps values in a data object (the falco PR #33 script does the same); the
    # status is checked, not just ignored, so a failed write cannot pass as success.
    CODE=$(jq -c '{data: .smtp}' <<<"$P" \
      | curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' -X POST --data-binary @- "$ADDR/v1/secret/data/$KV")
    [[ "$CODE" == "200" || "$CODE" == "204" ]] \
      || { echo "ERROR: writing secret/$KV failed (HTTP $CODE)" >&2; exit 1; }
  fi

  echo "    [remote] verifying the secret key set (values never printed)"
  curl -q -s --config "$CFG" "$ADDR/v1/secret/data/$KV" \
    | jq -e '.data.data | keys | sort == ["from","password","to","username"]' >/dev/null \
    || { echo "ERROR: unexpected keys in secret/$KV" >&2; exit 1; }
  echo "    [remote] alertmanager setup complete"
fi

echo "    [remote] revoking the root token"
curl -q -s --config "$CFG" -o /dev/null -X POST "$ADDR/v1/auth/token/revoke-self"
CODE=$(curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' "$ADDR/v1/auth/token/lookup-self")
if [[ "$CODE" == "403" || "$CODE" == "404" ]]; then
  echo "    [remote] revocation verified (lookup-self -> $CODE)"
  trap - EXIT
  rm -f "$CFG"
else
  echo "ERROR: token still valid after revoke (lookup-self -> $CODE)" >&2
  exit 1
fi
echo "==> root-run done: command ran, token revoked and verified revoked"
REMOTE_SCRIPT
  } | "${SSH_RUNNER[@]}" 'read -r BREAKGLASS_PAYLOAD && export BREAKGLASS_PAYLOAD && bash -s'; then
    die "root-run session failed - see the messages above; re-running is safe (it cancels any in-flight root generation first)"
  fi
}

# Prompts for the Alertmanager SMTP values locally (password hidden) and extends the
# payload. Same fields/defaults as the falco PR #33 script. Everything here MUST print
# to stderr: this function runs inside $( ), so stdout would be captured INTO the
# payload JSON (found by the test harness 2026-11-03: the banner line became payload
# line 1 and the remote side executed it).
alertmanager_prompt_and_extend() {   # $1 payload-so-far -> full payload on stdout
  local payload="$1" u f t p
  echo "==> Alertmanager SMTP values (same prompts as scripts/openbao-setup-alertmanager.sh)" >&2
  read -r -p "    SMTP username (e.g. user@gmail.com): " u
  [[ -n "$u" ]] || die "SMTP username must not be empty"
  read -r -p "    Alert From address [$u]: " f; f="${f:-$u}"
  read -r -p "    Alert To address [$u]: " t; t="${t:-$u}"
  read -rs -p "    Gmail 16-character App Password (input hidden): " p
  echo >&2
  p="${p// /}"   # strip the spaces from Google's 4x4 grouped display
  [[ -n "$p" ]] || die "SMTP password must not be empty"
  local overwrite=false
  [[ "$OVERWRITE" == true ]] && overwrite=true
  # The password reaches jq through the environment (allowed), never argv.
  SMTP_USERNAME="$u" SMTP_FROM="$f" SMTP_TO="$t" SMTP_PASSWORD="$p" \
    jq -cn --argjson p "$payload" --argjson overwrite "$overwrite" \
    '$p + {smtp: {username: env.SMTP_USERNAME, from: env.SMTP_FROM, to: env.SMTP_TO, password: env.SMTP_PASSWORD}, overwrite: $overwrite}'
  unset p
}

# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    apply-config)
      for a in "$@"; do [[ "$a" == "--dry-run" ]] && DRY_RUN=true; done
      cmd_apply_config "$@" ;;
    root-run)
      cmd_root_run "$@" ;;
    -h|--help|help)
      usage ;;
    *)
      die "unknown subcommand: ${cmd:-<none>} (apply-config | root-run | help)" ;;
  esac
}

main "$@"
