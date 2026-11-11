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
# Unseal shares, the SMTP app password, the OIDC client credentials, the healthchecks.io
# ping URL, and the govgraph database/Cloudflare values are read with `read -rs` locally
# and travel to sectools over ssh stdin (never argv, never echoed). The ping URL is a SECRET.
#
# Usage (owner, from the Mac):
#   scripts/openbao-breakglass.sh apply-config            # once: playbook + unseal
#   scripts/openbao-breakglass.sh root-run alertmanager   # the alert setup (§D step 5)
#   scripts/openbao-breakglass.sh root-run oidc <consumer> # OIDC client secrets (ADR 0016):
#       #      consumer = grafana | argocd | oauth2-proxy-prometheus | oauth2-proxy-alertmanager
#   scripts/openbao-breakglass.sh root-run watchdog-url   # PATCH watchdog_url on monitoring/alertmanager
#   scripts/openbao-breakglass.sh root-run nexus-pull     # registry pull credential + 3 ESO roles (ADR 0019)
#   scripts/openbao-breakglass.sh root-run tenant <app> <env>  # per-tenant policy + role (ADR 0019 D6)
#   scripts/openbao-breakglass.sh root-run cloudflared-token  # tunnel token for edge-public (ADR 0019 D7)
#   scripts/openbao-breakglass.sh root-run public-site-probes  # public apex+staging URLs for blackbox (never in git)
#   scripts/openbao-breakglass.sh root-run govgraph-secrets <staging|prod>  # govgraph app (+prod cloudflare) secrets (ADR 0019)
#   scripts/openbao-breakglass.sh root-run govgraph-probes  # govgraph probe URLs, PATCHed into the shared probe object
#   scripts/openbao-breakglass.sh root-run -- <cmd...>    # anything else with the token
#   everything also accepts --dry-run (and root-run alertmanager/oidc/nexus-pull/cloudflared-token/
#   public-site-probes/govgraph-probes: --overwrite)
#   govgraph-secrets: --overwrite (both objects), --overwrite-app (app only:
#     regenerates CRON_SECRET), --overwrite-cloudflare (prod CF object only:
#     keeps CRON_SECRET so web and refresh stay in agreement)
#
# `apply-config` runs (and prints) exactly:
#   cd ansible && ansible-playbook playbooks/openbao.yml --limit sectools --check --diff
#   cd ansible && ansible-playbook playbooks/openbao.yml --limit sectools
# The listener flag is startup-only (NOT SIGHUP-reloadable, verified 2026-11-03), so the
# playbook restarts openbao and the store comes back SEALED; apply-config then unseals it
# by piping one share at a time to PUT /v1/sys/unseal (the bao CLI refuses piped stdin
# for unseal - also verified - so the API it is), prompting hidden until it is unsealed.
#
# `root-run` (one ssh session): generate OTP, init, submit the 2 shares (the store's
# threshold: 3 shares / t=2, verified live 2026-11-03), decode into a remote variable,
# run the command with BAO_TOKEN set, then ALWAYS revoke the token - explicit revoke +
# verification, with a trap as the backstop on any failure.
#
# Why `root-run alertmanager`/`oidc` embed the setup instead of running a setup script
# through an `ssh -L` tunnel (ADR 0016 fix round): the tunnel would need BAO_TOKEN in a
# LOCAL environment variable, i.e. the root token would reach the Mac - exactly what this
# script exists to prevent. It would not even work: https://bao.home.arpa is reachable
# from the Mac (health 200, verified 2026-11-03) but Caddy 403s /v1/sys/generate-root*
# from the network (verified: 403), and OpenBao's listener binds 127.0.0.1 only, so root
# minting is sectools-only by design. The alertmanager payloads are copied from
# openbao-setup-alertmanager.sh (falco PR #33), which stays the reference for a flow where
# you already hold a short-lived token; the oidc payloads follow ADR 0016 decision 8.
#
# Undo of what `root-run alertmanager` writes (same as the falco PR #33 script):
#   curl -qsS -H "X-Vault-Token: <token>" -X DELETE "$ADDR/v1/secret/metadata/monitoring/alertmanager"
#   curl -qsS -H "X-Vault-Token: <token>" -X DELETE "$ADDR/v1/auth/kubernetes/role/alertmanager"
#   curl -qsS -H "X-Vault-Token: <token>" -X DELETE "$ADDR/v1/sys/policies/acl/alertmanager-read"
#
# Undo of what `root-run watchdog-url` writes (SMTP keys stay; do not DELETE the whole secret):
#   GET secret/data/monitoring/alertmanager, drop watchdog_url, POST the remaining keys.
#
# Undo of what `root-run oidc <consumer>` writes:
#   curl -qsS -H "X-Vault-Token: <token>" -X DELETE "$ADDR/v1/secret/metadata/oidc/<consumer>"
#   # role/policy are shared by every oidc consumer - delete only after removing ALL of them:
#   curl -qsS -H "X-Vault-Token: <token>" -X DELETE "$ADDR/v1/auth/kubernetes/role/oidc"
#   curl -qsS -H "X-Vault-Token: <token>" -X DELETE "$ADDR/v1/sys/policies/acl/oidc-read"
#
# Undo of what `root-run govgraph-secrets <env>` writes (KV v2: deleting the metadata path
# drops every version; the prod cloudflare path only exists for prod):
#   curl -qsS -H "X-Vault-Token: <token>" -X DELETE "$ADDR/v1/secret/metadata/apps/govgraph/<env>/app"
#   curl -qsS -H "X-Vault-Token: <token>" -X DELETE "$ADDR/v1/secret/metadata/apps/govgraph/prod/cloudflare"
#
# Undo of what `root-run govgraph-probes` writes (never DELETE the metadata: that drops the
# public-site URLs too - GET the object, remove the two govgraph keys, POST the rest):
#   GET secret/data/monitoring/public-site-probes, drop govgraph_apex_url + govgraph_staging_url,
#   POST the remaining keys.
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
OVERWRITE_APP=false   # govgraph-secrets only: replace just the app object (regenerate CRON_SECRET)
OVERWRITE_CF=false    # govgraph-secrets only: replace just the prod cloudflare object (keep CRON_SECRET)
SHARES_REQUIRED=2   # the store was inited 3 shares / 2 threshold (ADR 0014, runbook §2;
                    # verified live 2026-11-03: seal-status reports n=3, t=2)

# The ssh runner as an array: default "ssh tunsadmin@192.168.1.95"; tests override with e.g. "bash -c"
# (argv word splitting is safe here; the override never contains secrets).
read -r -a SSH_RUNNER <<<"${BREAKGLASS_SSH:-ssh -o BatchMode=yes tunsadmin@192.168.1.95}"
REMOTE_ADDR="${BREAKGLASS_BAO_ADDR:-http://127.0.0.1:8200}"
PLAYBOOK_DIR="${BREAKGLASS_PLAYBOOK_DIR:-$REPO_ROOT/ansible}"

# Print the header comment as the help text, stopping at the `set` line (robust to the
# header growing, unlike a fixed sed line range).
usage() { awk 'NR==1{next} /^set -euo pipefail$/{exit} {sub(/^# ?/,""); print}' "$0"; }

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
  local mode="exec" cmd_args=() OIDC_CONSUMER="" TENANT_APP="" TENANT_ENV="" GOVGRAPH_ENV=""
  local args=()
  [[ $# -gt 0 ]] || die "root-run needs a command: 'root-run alertmanager' or 'root-run -- <cmd...>'"
  # Named modes: `root-run <mode> ...`. An arbitrary command needs an explicit `--` BEFORE it:
  # `root-run -- <cmd...>`. A bare word that is not a known mode is refused, before any share
  # is asked for: twice (2026-11-09) a mode missing from a stale checkout ran as a "command"
  # with a root token. --dry-run/--overwrite/--overwrite-app/--overwrite-cloudflare are
  # peeled off anywhere.
  local a explicit_cmd=false
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY_RUN=true ;;
      --overwrite) OVERWRITE=true ;;
      --overwrite-app) OVERWRITE_APP=true ;;
      --overwrite-cloudflare) OVERWRITE_CF=true ;;
      --) [[ ${#args[@]} -eq 0 ]] && explicit_cmd=true ;;
      *) args+=("$a") ;;
    esac
  done
  [[ ${#args[@]} -eq 0 ]] && die "root-run needs a command after the flags"
  if [[ "${args[0]}" == "alertmanager" ]]; then
    mode="alertmanager"
    [[ ${#args[@]} -gt 1 ]] && die "root-run alertmanager takes no extra arguments (flags: --overwrite --dry-run)"
  elif [[ "${args[0]}" == "watchdog-url" ]]; then
    mode="watchdog"
    [[ ${#args[@]} -gt 1 ]] && die "root-run watchdog-url takes no extra arguments (flags: --dry-run)"
  elif [[ "${args[0]}" == "nexus-pull" ]]; then
    mode="nexuspull"
    [[ ${#args[@]} -gt 1 ]] && die "root-run nexus-pull takes no extra arguments (flags: --overwrite --dry-run)"
  elif [[ "${args[0]}" == "cloudflared-token" ]]; then
    mode="cloudflared"
    [[ ${#args[@]} -gt 1 ]] && die "root-run cloudflared-token takes no extra arguments (flags: --overwrite --dry-run)"
  elif [[ "${args[0]}" == "public-site-probes" ]]; then
    mode="publicsite"
    [[ ${#args[@]} -gt 1 ]] && die "root-run public-site-probes takes no extra arguments (flags: --overwrite --dry-run)"
  elif [[ "${args[0]}" == "govgraph-secrets" ]]; then
    mode="govgraph"
    [[ ${#args[@]} -eq 2 ]] || die "root-run govgraph-secrets takes exactly <staging|prod> (flags: --overwrite --overwrite-app --overwrite-cloudflare --dry-run)"
    case "${args[1]}" in
      staging|prod) GOVGRAPH_ENV="${args[1]}" ;;
      *) die "unknown govgraph-secrets environment: ${args[1]} (staging|prod)" ;;
    esac
  elif [[ "${args[0]}" == "govgraph-probes" ]]; then
    mode="govgraphprobes"
    [[ ${#args[@]} -gt 1 ]] && die "root-run govgraph-probes takes no extra arguments (flags: --overwrite --dry-run)"
  elif [[ "${args[0]}" == "tenant" ]]; then
    mode="tenant"
    [[ ${#args[@]} -eq 3 ]] || die "root-run tenant takes exactly <app> <env>"
    [[ "${args[1]}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && "${args[2]}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
      || die "tenant app/env must match ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"
    TENANT_APP="${args[1]}" TENANT_ENV="${args[2]}"
  elif [[ "${args[0]}" == "oidc" ]]; then
    mode="oidc"
    [[ ${#args[@]} -eq 2 ]] || die "root-run oidc takes exactly one consumer: grafana|argocd|oauth2-proxy-prometheus|oauth2-proxy-alertmanager"
    case "${args[1]}" in
      grafana|argocd|oauth2-proxy-prometheus|oauth2-proxy-alertmanager) OIDC_CONSUMER="${args[1]}" ;;
      *) die "unknown oidc consumer: ${args[1]} (grafana|argocd|oauth2-proxy-prometheus|oauth2-proxy-alertmanager)" ;;
    esac
  elif [[ "$explicit_cmd" == true ]]; then
    cmd_args=("${args[@]}")
  else
    die "unknown root-run mode '${args[0]}' (nothing asked, nothing minted).
    Known modes: alertmanager, watchdog-url, nexus-pull, cloudflared-token, tenant <app> <env>,
    oidc <consumer>, public-site-probes, govgraph-secrets <staging|prod>, govgraph-probes.
    A mode from a recently merged PR? Run 'git pull' first.
    To run an arbitrary command with the token: root-run -- <cmd...>"
  fi

  if [[ "$OVERWRITE_APP" == true || "$OVERWRITE_CF" == true ]]; then
    if [[ "$mode" != "govgraph" ]]; then
      die "--overwrite-app/--overwrite-cloudflare are govgraph-secrets only"
    fi
    local overwrite_flags=0
    [[ "$OVERWRITE" == true ]] && overwrite_flags=$((overwrite_flags+1))
    [[ "$OVERWRITE_APP" == true ]] && overwrite_flags=$((overwrite_flags+1))
    [[ "$OVERWRITE_CF" == true ]] && overwrite_flags=$((overwrite_flags+1))
    [[ "$overwrite_flags" -eq 1 ]] || die "pass exactly one of --overwrite, --overwrite-app, --overwrite-cloudflare"
    if [[ "$OVERWRITE_CF" == true && "$GOVGRAPH_ENV" == "staging" ]]; then
      die "staging writes no cloudflare object; use --overwrite or --overwrite-app"
    fi
  fi

  say "openbao break-glass root-run ($mode)"

  # Prompt locally for the shares (hidden). The store holds 3 shares with a threshold of
  # 2 (verified live 2026-11-03: seal-status n=3, t=2); the count is a constant so the
  # flow stays ONE command and ONE session. --dry-run
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
  payload=$(SHARES_JSON="$shares_json" jq -cn --arg addr "$REMOTE_ADDR" '{addr: $addr, shares: (env.SHARES_JSON|fromjson)}')
  unset s shares shares_json

  if [[ "$mode" == "alertmanager" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      payload=$(PAYLOAD="$payload" jq -cn \
        '(env.PAYLOAD|fromjson) + {smtp: {username: "<prompted>", from: "<prompted>", to: "<prompted>", password: "<hidden>"}, overwrite: false}')
    else
      payload=$(alertmanager_prompt_and_extend "$payload")
    fi
  elif [[ "$mode" == "oidc" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      payload=$(PAYLOAD="$payload" jq -cn --arg c "$OIDC_CONSUMER" \
        '(env.PAYLOAD|fromjson) + {oidc: {consumer: $c, client_id: "<hidden>", client_secret: "<hidden>"}, overwrite: false}')
    else
      payload=$(oidc_prompt_and_extend "$payload" "$OIDC_CONSUMER")
    fi
  elif [[ "$mode" == "nexuspull" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      payload=$(PAYLOAD="$payload" jq -cn '(env.PAYLOAD|fromjson) + {nexuspull: {username: "k8s-pull", password: "<hidden>"}, overwrite: false}')
    else
      payload=$(nexuspull_fetch_and_extend "$payload")
    fi
  elif [[ "$mode" == "tenant" ]]; then
    payload=$(PAYLOAD="$payload" jq -cn --arg a "$TENANT_APP" --arg e "$TENANT_ENV" '(env.PAYLOAD|fromjson) + {tenant: {app: $a, env: $e}}')
  elif [[ "$mode" == "cloudflared" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      payload=$(PAYLOAD="$payload" jq -cn \
        '(env.PAYLOAD|fromjson) + {cloudflared: {tunnel_token: "<hidden>", nchars: 0}, overwrite: false}')
    else
      payload=$(cloudflared_prompt_and_extend "$payload")
    fi
  elif [[ "$mode" == "publicsite" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      payload=$(PAYLOAD="$payload" jq -cn \
        '(env.PAYLOAD|fromjson) + {publicsite: {apex_url: "<hidden>", staging_url: "<hidden>", apex_nchars: 0, staging_nchars: 0}, overwrite: false}')
    else
      payload=$(publicsite_prompt_and_extend "$payload")
    fi
  elif [[ "$mode" == "govgraph" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      payload=$(PAYLOAD="$payload" jq -cn --arg e "$GOVGRAPH_ENV" \
        '(env.PAYLOAD|fromjson) + {govgraph: {env: $e, database_url: "<hidden>", zone_id: "<hidden>", api_token: "<hidden>", overwrite_app: false, overwrite_cf: false}}')
    else
      payload=$(govgraph_prompt_and_extend "$payload" "$GOVGRAPH_ENV")
    fi
  elif [[ "$mode" == "govgraphprobes" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      payload=$(PAYLOAD="$payload" jq -cn \
        '(env.PAYLOAD|fromjson) + {govgraphprobes: {apex_url: "<hidden>", staging_url: "<hidden>", apex_nchars: 0, staging_nchars: 0}, overwrite: false}')
    else
      payload=$(govgraphprobes_prompt_and_extend "$payload")
    fi
  elif [[ "$mode" == "watchdog" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      payload=$(PAYLOAD="$payload" jq -cn \
        '(env.PAYLOAD|fromjson) + {watchdog: {url: "<hidden>", nchars: 0}}')
    else
      payload=$(watchdog_prompt_and_extend "$payload")
    fi
  else
    # Shell-quoted so the remote bash -c runs exactly this command; the command is the
    # operator's own text, not a secret, but quoting keeps word boundaries intact.
    local cmd_quoted
    cmd_quoted=$(printf '%q ' "${cmd_args[@]}")
    payload=$(PAYLOAD="$payload" jq -cn --arg c "$cmd_quoted" '(env.PAYLOAD|fromjson) + {cmd: $c}')
    say "command that will run on sectools with the root token: ${cmd_quoted% }"
    note "its output is printed as-is - do not run commands that print secret values"
  fi

  if [[ "$DRY_RUN" == true && "$mode" == "govgraph" ]]; then
    say "govgraph-secrets plan ($GOVGRAPH_ENV):"
    note "write secret/apps/govgraph/$GOVGRAPH_ENV/app - keys: DATABASE_URL (prompted hidden, shape-checked locally),"
    note "CRON_SECRET (generated on sectools: 32 random bytes, hex - never prompted, never printed)"
    if [[ "$GOVGRAPH_ENV" == "prod" ]]; then
      note "write secret/apps/govgraph/prod/cloudflare - keys: CF_ZONE_ID (32 hex), CF_API_TOKEN (both prompted hidden)"
    else
      note "no cloudflare object (staging does not purge)"
    fi
    if [[ "$OVERWRITE_APP" == true || "$OVERWRITE_CF" == true ]]; then
      local which_over
      if [[ "$OVERWRITE_APP" == true ]]; then which_over="--overwrite-app: replaces the app object only (CRON_SECRET is regenerated)"
      else which_over="--overwrite-cloudflare: replaces the prod cloudflare object only (CRON_SECRET is kept so web and refresh stay in agreement)"
      fi
      note "existing objects are kept without a flag; $which_over"
    else
      note "existing objects are kept without --overwrite; with it both objects are replaced (CRON_SECRET is regenerated)"
    fi
  fi
  if [[ "$DRY_RUN" == true && "$mode" == "govgraphprobes" ]]; then
    say "govgraph-probes plan:"
    note "PATCH secret/monitoring/public-site-probes - add keys: govgraph_apex_url, govgraph_staging_url"
    note "(both prompted hidden, https, trailing slash; the write is check-and-set on the"
    note "current version, and a stray key or a lone govgraph key is refused before writing)"
    note "existing apex_url/staging_url are kept untouched; existing govgraph keys are refused without --overwrite"
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
MODE=$(jq -r 'if .cmd then "exec" elif .oidc then "oidc" elif .watchdog then "watchdog" elif .nexuspull then "nexuspull" elif .tenant then "tenant" elif .cloudflared then "cloudflared" elif .publicsite then "publicsite" elif .govgraph then "govgraph" elif .govgraphprobes then "govgraphprobes" else "alertmanager" end' <<<"$P")

echo "    [remote] health check"
curl -q -s "$ADDR/v1/sys/health" | jq -e '.initialized and (.sealed | not)' >/dev/null \
  || { echo "ERROR: OpenBao at $ADDR is not initialized+unsealed (run apply-config / runbook section 3 first)" >&2; exit 1; }

echo "    [remote] cancelling any in-flight root generation (idempotent)"
curl -q -s -o /dev/null -X DELETE "$ADDR/v1/sys/generate-root/attempt" || true

# OTP: client-side random base62, the same alphabet/length the CLI uses. In-process
# python3, not `tr | head`: with pipefail, head closing the pipe early SIGPIPE-kills tr
# and the whole session (found by the test harness; secrets.choice is also stronger).
# The OTP and each share reach jq through its environment, never argv (the OTP decodes
# the minted token; a share in argv would be visible in any process listing).
OTP=$(python3 -c '
import secrets, string
print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(26)))')
NONCE=$(OTP="$OTP" jq -n '{otp: env.OTP}' \
  | curl -q -s -X PUT --data-binary @- "$ADDR/v1/sys/generate-root/attempt" | jq -r '.nonce // empty')
[[ -n "$NONCE" ]] || { echo "ERROR: generate-root init failed (is the listener flag set?) - run apply-config" >&2; exit 1; }

RESP=""
n=0
while IFS= read -r share; do
  [[ -z "$share" ]] && continue
  n=$((n+1))
  RESP=$(SHARE="$share" jq -n --arg nonce "$NONCE" '{key: env.SHARE, nonce: $nonce}' \
    | curl -q -s -X PUT --data-binary @- "$ADDR/v1/sys/generate-root/update")
  echo "    [remote] share $n accepted: $(jq -c '{complete, progress, errors}' <<<"$RESP")"
  # Break the moment the threshold is met: the store holds 3 shares with a
  # threshold of 2 (verified live 2026-11-03: seal-status n=3, t=2), and
  # submitting past "complete" would error. Two prompts satisfy it.
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
elif [[ "$MODE" == "oidc" ]]; then
  # ---- the OIDC setup (ADR 0016 decision 8; same call shape as alertmanager) ----
  CONSUMER=$(jq -r '.oidc.consumer' <<<"$P")
  KV=oidc/$CONSUMER
  echo "    [remote] checking mounts (kv v2 at secret/, kubernetes auth)"
  curl -q -s --config "$CFG" "$ADDR/v1/sys/mounts" | jq -e '.["secret/"].options.version == "2"' >/dev/null \
    || { echo "ERROR: kv v2 is not mounted at secret/" >&2; exit 1; }
  curl -q -s --config "$CFG" "$ADDR/v1/sys/auth" | jq -e '.["kubernetes/"].type == "kubernetes"' >/dev/null \
    || { echo "ERROR: kubernetes auth missing (run openbao-setup-belleshop.sh first)" >&2; exit 1; }

  echo "    [remote] writing policy oidc-read (read-only on the ESO-consumed secret/data/oidc/* paths)"
  POLICY=$(cat <<'HCL'
# Least-privilege read policy for ESO OIDC client secrets in namespace monitoring (ADR 0016
# step 1; consumers are ExternalSecret grafana-oidc today, the two oauth2-proxy instances of
# ADR 0016 step 3 later). secret/data/oidc/argocd is NOT here on purpose: the owner reads it
# over the admin SSH path (Argo CD is out-of-git, ADR 0008).
path "secret/data/oidc/grafana" {
  capabilities = ["read"]
}
path "secret/data/oidc/oauth2-proxy-prometheus" {
  capabilities = ["read"]
}
path "secret/data/oidc/oauth2-proxy-alertmanager" {
  capabilities = ["read"]
}
HCL
)
  jq -n --arg policy "$POLICY" '{policy: $policy}' \
    | curl -q -s -o /dev/null --config "$CFG" -X PUT --data-binary @- "$ADDR/v1/sys/policies/acl/oidc-read"

  echo "    [remote] writing kubernetes auth role oidc (SA monitoring/eso-oidc)"
  jq -n '{bound_service_account_names: ["eso-oidc"], bound_service_account_namespaces: ["monitoring"], token_policies: ["oidc-read"], token_ttl: "1h"}' \
    | curl -q -s -o /dev/null --config "$CFG" -X POST --data-binary @- "$ADDR/v1/auth/kubernetes/role/oidc"

  EXISTS=$(curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' "$ADDR/v1/secret/metadata/$KV")
  OVER=$(jq -r '.overwrite // false' <<<"$P")
  if [[ "$EXISTS" == "200" && "$OVER" != "true" ]]; then
    echo "    [remote] secret/$KV already exists (pass --overwrite to replace)"
  else
    echo "    [remote] writing secret/$KV with the prompted Gitea OAuth2 credentials"
    # The client id/secret arrive in the payload (ssh stdin, never argv). The cookie
    # secret for the oauth2-proxy consumers is generated HERE on sectools - it never
    # touches the Mac at all. oauth2-proxy wants 16/24/32 raw bytes base64-encoded;
    # python3, not `openssl | head`: with pipefail, head closing the pipe early
    # SIGPIPE-kills the producer (same lesson as the OTP generation above).
    if [[ "$CONSUMER" == oauth2-proxy-* ]]; then
      COOKIE_SECRET=$(python3 -c 'import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())')
      CODE=$(CS="$COOKIE_SECRET" jq -c '{data: {client_id: .oidc.client_id, client_secret: .oidc.client_secret, cookie_secret: env.CS}}' <<<"$P" \
        | curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' -X POST --data-binary @- "$ADDR/v1/secret/data/$KV")
      unset COOKIE_SECRET
    else
      CODE=$(jq -c '{data: {client_id: .oidc.client_id, client_secret: .oidc.client_secret}}' <<<"$P" \
        | curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' -X POST --data-binary @- "$ADDR/v1/secret/data/$KV")
    fi
    [[ "$CODE" == "200" || "$CODE" == "204" ]] \
      || { echo "ERROR: writing secret/$KV failed (HTTP $CODE)" >&2; exit 1; }
  fi

  echo "    [remote] verifying the secret key set (values never printed)"
  if [[ "$CONSUMER" == oauth2-proxy-* ]]; then
    EXPECTED='["client_id","client_secret","cookie_secret"]'
  else
    EXPECTED='["client_id","client_secret"]'
  fi
  curl -q -s --config "$CFG" "$ADDR/v1/secret/data/$KV" \
    | jq -e --argjson exp "$EXPECTED" '.data.data | keys | sort == $exp' >/dev/null \
    || { echo "ERROR: unexpected keys in secret/$KV" >&2; exit 1; }
  echo "    [remote] oidc setup complete ($CONSUMER)"
elif [[ "$MODE" == "nexuspull" ]]; then
  # ---- registry pull credential for ESO (ADR 0019 Phase 0) ----
  echo "    [remote] checking mounts (kv v2 at secret/, kubernetes auth)"
  curl -q -s --config "$CFG" "$ADDR/v1/sys/mounts" | jq -e '.["secret/"].options.version == "2"' >/dev/null \
    || { echo "ERROR: kv v2 is not mounted at secret/" >&2; exit 1; }
  curl -q -s --config "$CFG" "$ADDR/v1/sys/auth" | jq -e '.["kubernetes/"]' >/dev/null \
    || { echo "ERROR: kubernetes auth is not enabled" >&2; exit 1; }
  echo "    [remote] writing policy nexus-pull-read (read secret/data/platform/nexus-pull only)"
  jq -n --arg policy 'path "secret/data/platform/nexus-pull" {
  capabilities = ["read"]
}' '{policy: $policy}' \
    | curl -q -s -o /dev/null --config "$CFG" -X PUT --data-binary @- "$ADDR/v1/sys/policies/acl/nexus-pull-read"
  for NS in dev kyverno argo-rollouts; do
    echo "    [remote] writing kubernetes auth role nexus-pull-$NS (SA $NS/eso-nexus-pull)"
    jq -n --arg ns "$NS" '{bound_service_account_names: ["eso-nexus-pull"], bound_service_account_namespaces: [$ns], token_policies: ["nexus-pull-read"], token_ttl: "1h"}' \
      | curl -q -s -o /dev/null --config "$CFG" -X POST --data-binary @- "$ADDR/v1/auth/kubernetes/role/nexus-pull-$NS"
  done
  EXISTS=$(curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' "$ADDR/v1/secret/metadata/platform/nexus-pull")
  OVER=$(jq -r '.overwrite // false' <<<"$P")
  if [[ "$EXISTS" == "200" && "$OVER" != "true" ]]; then
    echo "    [remote] secret/platform/nexus-pull already exists (pass --overwrite to replace)"
  else
    echo "    [remote] writing secret/platform/nexus-pull (username + password; values never printed)"
    CODE=$(jq -c '{data: .nexuspull}' <<<"$P" \
      | curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' -X POST --data-binary @- "$ADDR/v1/secret/data/platform/nexus-pull")
    [[ "$CODE" == "200" || "$CODE" == "204" ]] \
      || { echo "ERROR: writing secret/platform/nexus-pull failed (HTTP $CODE)" >&2; exit 1; }
  fi
  curl -q -s --config "$CFG" "$ADDR/v1/secret/data/platform/nexus-pull" \
    | jq -e '.data.data | (keys == ["password","username"]) and (.password | length > 0)' >/dev/null \
    || { echo "ERROR: secret/platform/nexus-pull does not hold exactly username+password" >&2; exit 1; }
  echo "    [remote] nexus-pull setup complete"
elif [[ "$MODE" == "tenant" ]]; then
  # ---- per-tenant least-privilege access (ADR 0019 D6) ----
  APP=$(jq -r .tenant.app <<<"$P"); ENVN=$(jq -r .tenant.env <<<"$P")
  [[ "$APP" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && "$ENVN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
    || { echo "ERROR: bad tenant name" >&2; exit 1; }
  NAME="tenant-$APP-$ENVN"
  echo "    [remote] writing policy $NAME (read secret/data/apps/$APP/$ENVN/* + the shared pull credential)"
  POLICY=$(printf 'path "secret/data/apps/%s/%s/*" {\n  capabilities = ["read"]\n}\npath "secret/data/platform/nexus-pull" {\n  capabilities = ["read"]\n}\n' "$APP" "$ENVN")
  jq -n --arg policy "$POLICY" '{policy: $policy}' \
    | curl -q -s -o /dev/null --config "$CFG" -X PUT --data-binary @- "$ADDR/v1/sys/policies/acl/$NAME"
  echo "    [remote] writing kubernetes auth role $NAME (SA $APP-$ENVN/eso)"
  jq -n --arg ns "$APP-$ENVN" --arg pol "$NAME" '{bound_service_account_names: ["eso"], bound_service_account_namespaces: [$ns], token_policies: [$pol], token_ttl: "1h"}' \
    | curl -q -s -o /dev/null --config "$CFG" -X POST --data-binary @- "$ADDR/v1/auth/kubernetes/role/$NAME"
  curl -q -s --config "$CFG" "$ADDR/v1/auth/kubernetes/role/$NAME" \
    | jq -e --arg ns "$APP-$ENVN" --arg pol "$NAME" '.data.bound_service_account_namespaces == [$ns] and .data.token_policies == [$pol]' >/dev/null \
    || { echo "ERROR: role $NAME did not read back as written" >&2; exit 1; }
  echo "    [remote] tenant $APP-$ENVN setup complete"
elif [[ "$MODE" == "cloudflared" ]]; then
  # ---- Cloudflare Tunnel token for edge-public/eso (ADR 0019 D7) ----
  echo "    [remote] checking mounts (kv v2 at secret/, kubernetes auth)"
  curl -q -s --config "$CFG" "$ADDR/v1/sys/mounts" | jq -e '.["secret/"].options.version == "2"' >/dev/null \
    || { echo "ERROR: kv v2 is not mounted at secret/" >&2; exit 1; }
  curl -q -s --config "$CFG" "$ADDR/v1/sys/auth" | jq -e '.["kubernetes/"]' >/dev/null \
    || { echo "ERROR: kubernetes auth is not enabled" >&2; exit 1; }
  echo "    [remote] writing policy cloudflared-read (read secret/data/platform/cloudflared only)"
  jq -n --arg policy 'path "secret/data/platform/cloudflared" {
  capabilities = ["read"]
}' '{policy: $policy}' \
    | curl -q -s -o /dev/null --config "$CFG" -X PUT --data-binary @- "$ADDR/v1/sys/policies/acl/cloudflared-read"
  echo "    [remote] writing kubernetes auth role cloudflared (SA edge-public/eso)"
  jq -n '{bound_service_account_names: ["eso"], bound_service_account_namespaces: ["edge-public"], token_policies: ["cloudflared-read"], token_ttl: "1h"}' \
    | curl -q -s -o /dev/null --config "$CFG" -X POST --data-binary @- "$ADDR/v1/auth/kubernetes/role/cloudflared"
  EXISTS=$(curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' "$ADDR/v1/secret/metadata/platform/cloudflared")
  OVER=$(jq -r '.overwrite // false' <<<"$P")
  if [[ "$EXISTS" == "200" && "$OVER" != "true" ]]; then
    echo "    [remote] secret/platform/cloudflared already exists (pass --overwrite to replace)"
    curl -q -s --config "$CFG" "$ADDR/v1/secret/data/platform/cloudflared" \
      | jq -e '.data.data | keys == ["tunnel_token"]' >/dev/null \
      || { echo "ERROR: existing secret/platform/cloudflared does not hold exactly tunnel_token" >&2; exit 1; }
  else
    echo "    [remote] writing secret/platform/cloudflared (tunnel_token; value never printed)"
    CODE=$(jq -c '{data: {tunnel_token: .cloudflared.tunnel_token}}' <<<"$P" \
      | curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' -X POST --data-binary @- "$ADDR/v1/secret/data/platform/cloudflared")
    [[ "$CODE" == "200" || "$CODE" == "204" ]] \
      || { echo "ERROR: writing secret/platform/cloudflared failed (HTTP $CODE)" >&2; exit 1; }
    NCHARS=$(jq -r '.cloudflared.nchars' <<<"$P")
    curl -q -s --config "$CFG" "$ADDR/v1/secret/data/platform/cloudflared" \
      | jq -e --argjson n "$NCHARS" \
        '(.data.data | keys == ["tunnel_token"]) and ((.data.data.tunnel_token | length) == $n)' >/dev/null \
      || { echo "ERROR: secret/platform/cloudflared does not hold exactly tunnel_token of the expected length" >&2; exit 1; }
    echo "    [remote] stored ($NCHARS chars)"
  fi
  echo "    [remote] cloudflared-token setup complete"
elif [[ "$MODE" == "publicsite" ]]; then
  # ---- public-path blackbox targets (hostnames never in git) ----
  KV=monitoring/public-site-probes
  echo "    [remote] checking mounts (kv v2 at secret/, kubernetes auth)"
  curl -q -s --config "$CFG" "$ADDR/v1/sys/mounts" | jq -e '.["secret/"].options.version == "2"' >/dev/null \
    || { echo "ERROR: kv v2 is not mounted at secret/" >&2; exit 1; }
  curl -q -s --config "$CFG" "$ADDR/v1/sys/auth" | jq -e '.["kubernetes/"]' >/dev/null \
    || { echo "ERROR: kubernetes auth is not enabled" >&2; exit 1; }
  echo "    [remote] writing policy public-site-probes-read (read secret/data/monitoring/public-site-probes only)"
  jq -n --arg policy 'path "secret/data/monitoring/public-site-probes" {
  capabilities = ["read"]
}' '{policy: $policy}' \
    | curl -q -s -o /dev/null --config "$CFG" -X PUT --data-binary @- "$ADDR/v1/sys/policies/acl/public-site-probes-read"
  echo "    [remote] writing kubernetes auth role public-site-probes (SA monitoring/eso-public-site-probes)"
  jq -n '{bound_service_account_names: ["eso-public-site-probes"], bound_service_account_namespaces: ["monitoring"], token_policies: ["public-site-probes-read"], token_ttl: "1h"}' \
    | curl -q -s -o /dev/null --config "$CFG" -X POST --data-binary @- "$ADDR/v1/auth/kubernetes/role/public-site-probes"
  EXISTS=$(curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' "$ADDR/v1/secret/metadata/$KV")
  OVER=$(jq -r '.overwrite // false' <<<"$P")
  # The object is shared with the govgraph probe URLs (govgraph-probes PATCHes its two
  # keys into it), so this mode merges instead of blind-putting: apex_url/staging_url are
  # replaced (or created) and the govgraph pair is carried over untouched. The write is a
  # KV v2 check-and-set (options.cas = the version that was read), so a concurrent writer
  # cannot be silently clobbered. A stray (unknown) key is rejected up front, before
  # anything is written; --overwrite repairs an object whose KNOWN keys are wrong
  # (missing base pair, lone govgraph key) by writing the canonical content.
  EXISTING='{}' CAS=0 CARRY='{}'
  if [[ "$EXISTS" == "200" ]]; then
    curl -q -s --config "$CFG" "$ADDR/v1/secret/data/$KV" >"$CFG.body"
    EXISTING=$(jq -c '.data.data' "$CFG.body") CAS=$(jq -r '.data.metadata.version' "$CFG.body")
    rm -f "$CFG.body"
    jq -e '([keys[]] - ["apex_url","staging_url","govgraph_apex_url","govgraph_staging_url"]) | length == 0' <<<"$EXISTING" >/dev/null \
      || { echo "ERROR: secret/$KV holds keys other than the four probe keys; remove the stray key(s) first (nothing written)" >&2; exit 1; }
    if [[ "$OVER" != "true" ]]; then
      jq -e 'has("apex_url") and has("staging_url")
        and (has("govgraph_apex_url") == has("govgraph_staging_url"))' <<<"$EXISTING" >/dev/null \
        || { echo "ERROR: existing secret/$KV is malformed (pass --overwrite to repair; nothing written)" >&2; exit 1; }
    fi
    if jq -e 'has("govgraph_apex_url") and has("govgraph_staging_url")' <<<"$EXISTING" >/dev/null; then
      CARRY=$(jq -c '{govgraph_apex_url, govgraph_staging_url}' <<<"$EXISTING")
    fi
  fi
  if [[ "$EXISTS" == "200" && "$OVER" != "true" ]]; then
    echo "    [remote] secret/$KV already exists (pass --overwrite to replace)"
  else
    echo "    [remote] writing secret/$KV (apex_url, staging_url; the govgraph pair kept when present; values never printed; cas $CAS)"
    # The govgraph pair rides jq's environment (never argv) when it is carried over.
    CODE=$(CARRY="$CARRY" jq -c --argjson cas "$CAS" \
      '{options: {cas: $cas}, data: ((env.CARRY|fromjson) + {apex_url: .publicsite.apex_url, staging_url: .publicsite.staging_url})}' <<<"$P" \
      | curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' -X POST --data-binary @- "$ADDR/v1/secret/data/$KV")
    [[ "$CODE" == "200" || "$CODE" == "204" ]] \
      || { echo "ERROR: writing secret/$KV failed (HTTP $CODE; a check-and-set mismatch means another writer raced this run - re-run it)" >&2; exit 1; }
    AN=$(jq -r '.publicsite.apex_nchars' <<<"$P")
    SN=$(jq -r '.publicsite.staging_nchars' <<<"$P")
    curl -q -s --config "$CFG" "$ADDR/v1/secret/data/$KV" \
      | CARRY="$CARRY" jq -e --argjson a "$AN" --argjson s "$SN" \
        '(.data.data | ((keys | sort) == ["apex_url","staging_url"] or (keys | sort) == ["apex_url","govgraph_apex_url","govgraph_staging_url","staging_url"]))
         and ((.data.data.apex_url | length) == $a)
         and ((.data.data.staging_url | length) == $s)
         and (.data.data.govgraph_apex_url == (env.CARRY|fromjson).govgraph_apex_url)
         and (.data.data.govgraph_staging_url == (env.CARRY|fromjson).govgraph_staging_url)' >/dev/null \
      || { echo "ERROR: secret/$KV does not hold apex_url+staging_url of the expected lengths with the govgraph keys intact" >&2; exit 1; }
    echo "    [remote] stored (apex $AN chars, staging $SN chars)"
  fi
  echo "    [remote] public-site-probes setup complete"
elif [[ "$MODE" == "govgraph" ]]; then
  # ---- govgraph app (+prod Cloudflare) secrets (ADR 0019; argv-free on both sides) ----
  ENVN=$(jq -r '.govgraph.env' <<<"$P")
  [[ "$ENVN" == "staging" || "$ENVN" == "prod" ]] || { echo "ERROR: govgraph-secrets env must be staging or prod" >&2; exit 1; }
  KV="apps/govgraph/$ENVN/app"
  OVER_APP=$(jq -r '.govgraph.overwrite_app // false' <<<"$P")
  OVER_CF=$(jq -r '.govgraph.overwrite_cf // false' <<<"$P")
  EXISTS=$(curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' "$ADDR/v1/secret/metadata/$KV")
  if [[ "$EXISTS" == "200" && "$OVER_APP" != "true" ]]; then
    # Verify what is stored, not just that metadata answers 200 (a hand-mangled object or
    # a soft-deleted latest version would otherwise pass as success and leave the tenant
    # ExternalSecret broken).
    HTTPD=$(curl -q -s --config "$CFG" -o "$CFG.body" -w '%{http_code}' "$ADDR/v1/secret/data/$KV")
    if [[ "$HTTPD" != "200" ]]; then
      rm -f "$CFG.body"
      echo "ERROR: secret/$KV data is unreadable (HTTP $HTTPD) - pass --overwrite to repair" >&2; exit 1
    fi
    jq -e '.data.data | (keys | sort == ["CRON_SECRET","DATABASE_URL"]) and (.CRON_SECRET | test("^[0-9a-f]{64}$"))' "$CFG.body" >/dev/null \
      || { rm -f "$CFG.body"; echo "ERROR: secret/$KV does not hold exactly DATABASE_URL + a 64-hex CRON_SECRET - pass --overwrite to repair" >&2; exit 1; }
    rm -f "$CFG.body"
    echo "    [remote] secret/$KV already exists (kept; pass --overwrite or --overwrite-app to replace; CRON_SECRET kept so web and refresh stay in agreement)"
  else
    # CRON_SECRET is generated HERE on sectools (32 random bytes, hex): never prompted,
    # never on the Mac, never printed. It reaches curl via jq's environment and stdin;
    # DATABASE_URL arrives in the payload (ssh stdin). Nothing rides argv on this side.
    CRON_SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
    echo "    [remote] writing secret/$KV (DATABASE_URL from the payload, CRON_SECRET generated on sectools; values never printed)"
    CODE=$(CRON_SECRET="$CRON_SECRET" jq -c '{data: {DATABASE_URL: .govgraph.database_url, CRON_SECRET: env.CRON_SECRET}}' <<<"$P" \
      | curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' -X POST --data-binary @- "$ADDR/v1/secret/data/$KV")
    unset CRON_SECRET
    [[ "$CODE" == "200" || "$CODE" == "204" ]] \
      || { echo "ERROR: writing secret/$KV failed (HTTP $CODE)" >&2; exit 1; }
    curl -q -s --config "$CFG" "$ADDR/v1/secret/data/$KV" \
      | jq -e '.data.data | (keys | sort == ["CRON_SECRET","DATABASE_URL"]) and (.CRON_SECRET | test("^[0-9a-f]{64}$"))' >/dev/null \
      || { echo "ERROR: secret/$KV does not hold exactly DATABASE_URL + a 64-hex CRON_SECRET" >&2; exit 1; }
  fi
  VERSION=$(curl -q -s --config "$CFG" "$ADDR/v1/secret/metadata/$KV" | jq -r '.data.current_version')
  echo "    [remote] secret/$KV keys: DATABASE_URL, CRON_SECRET (version $VERSION)"
  if [[ "$ENVN" == "prod" ]]; then
    KVCF="apps/govgraph/prod/cloudflare"
    EX=$(curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' "$ADDR/v1/secret/metadata/$KVCF")
    if [[ "$EX" == "200" && "$OVER_CF" != "true" ]]; then
      HTTPD=$(curl -q -s --config "$CFG" -o "$CFG.body" -w '%{http_code}' "$ADDR/v1/secret/data/$KVCF")
      if [[ "$HTTPD" != "200" ]]; then
        rm -f "$CFG.body"
        echo "ERROR: secret/$KVCF data is unreadable (HTTP $HTTPD) - pass --overwrite or --overwrite-cloudflare to repair" >&2; exit 1
      fi
      jq -e '.data.data | keys | sort == ["CF_API_TOKEN","CF_ZONE_ID"]' "$CFG.body" >/dev/null \
        || { rm -f "$CFG.body"; echo "ERROR: secret/$KVCF does not hold exactly CF_ZONE_ID + CF_API_TOKEN - pass --overwrite or --overwrite-cloudflare to repair" >&2; exit 1; }
      rm -f "$CFG.body"
      echo "    [remote] secret/$KVCF already exists (kept; pass --overwrite or --overwrite-cloudflare to replace - rotating only the Cloudflare values keeps CRON_SECRET)"
    else
      echo "    [remote] writing secret/$KVCF (CF_ZONE_ID, CF_API_TOKEN from the payload; values never printed)"
      CODE=$(jq -c '{data: {CF_ZONE_ID: .govgraph.zone_id, CF_API_TOKEN: .govgraph.api_token}}' <<<"$P" \
        | curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' -X POST --data-binary @- "$ADDR/v1/secret/data/$KVCF")
      [[ "$CODE" == "200" || "$CODE" == "204" ]] \
        || { echo "ERROR: writing secret/$KVCF failed (HTTP $CODE)" >&2; exit 1; }
      curl -q -s --config "$CFG" "$ADDR/v1/secret/data/$KVCF" \
        | jq -e '.data.data | keys | sort == ["CF_API_TOKEN","CF_ZONE_ID"]' >/dev/null \
        || { echo "ERROR: secret/$KVCF does not hold exactly CF_ZONE_ID + CF_API_TOKEN" >&2; exit 1; }
    fi
    VERSIONCF=$(curl -q -s --config "$CFG" "$ADDR/v1/secret/metadata/$KVCF" | jq -r '.data.current_version')
    echo "    [remote] secret/$KVCF keys: CF_ZONE_ID, CF_API_TOKEN (version $VERSIONCF)"
  else
    echo "    [remote] staging: no cloudflare object (staging does not purge)"
  fi
  echo "    [remote] govgraph-secrets setup complete ($ENVN)"
elif [[ "$MODE" == "govgraphprobes" ]]; then
  # ---- govgraph probe URLs: PATCH two keys into the SHARED public-site object ----
  # Never a blind put: apex_url/staging_url (public-site-probes' keys) are carried over
  # untouched, and the write is a KV v2 check-and-set (options.cas = the version that was
  # read), so a concurrent writer cannot be silently clobbered. The object must exist with
  # its base pair (public-site-probes creates it; this mode cannot write those keys). A
  # stray key is rejected before anything is written; --overwrite repairs a lone govgraph
  # key by writing the canonical pair.
  KV=monitoring/public-site-probes
  echo "    [remote] checking mounts (kv v2 at secret/)"
  curl -q -s --config "$CFG" "$ADDR/v1/sys/mounts" | jq -e '.["secret/"].options.version == "2"' >/dev/null \
    || { echo "ERROR: kv v2 is not mounted at secret/" >&2; exit 1; }
  HTTP=$(curl -q -s --config "$CFG" -o "$CFG.body" -w '%{http_code}' "$ADDR/v1/secret/data/$KV")
  [[ "$HTTP" == "200" ]] || { echo "ERROR: secret/$KV missing (HTTP $HTTP) - run root-run public-site-probes first" >&2; rm -f "$CFG.body"; exit 1; }
  EXISTING=$(jq -c '.data.data' "$CFG.body") CAS=$(jq -r '.data.metadata.version' "$CFG.body")
  rm -f "$CFG.body"
  jq -e '([keys[]] - ["apex_url","staging_url","govgraph_apex_url","govgraph_staging_url"]) | length == 0' <<<"$EXISTING" >/dev/null \
    || { echo "ERROR: secret/$KV holds keys other than the four probe keys; remove the stray key(s) first (nothing written)" >&2; exit 1; }
  jq -e 'has("apex_url") and has("staging_url")' <<<"$EXISTING" >/dev/null \
    || { echo "ERROR: secret/$KV lacks apex_url/staging_url - run root-run public-site-probes (with --overwrite if malformed) first" >&2; exit 1; }
  OVER=$(jq -r '.overwrite // false' <<<"$P")
  HASPAIR=false
  jq -e 'has("govgraph_apex_url") and has("govgraph_staging_url")' <<<"$EXISTING" >/dev/null && HASPAIR=true
  HASLONE=false
  jq -e '(has("govgraph_apex_url") != has("govgraph_staging_url"))' <<<"$EXISTING" >/dev/null && HASLONE=true
  if [[ "$HASLONE" == true && "$OVER" != "true" ]]; then
    echo "ERROR: secret/$KV holds only one of the two govgraph keys (pass --overwrite to repair; nothing written)" >&2; exit 1
  fi
  if [[ "$HASPAIR" == true && "$OVER" != "true" ]]; then
    echo "    [remote] govgraph probe URLs already exist in secret/$KV (pass --overwrite to replace)"
  else
    echo "    [remote] PATCHing secret/$KV (govgraph_apex_url + govgraph_staging_url; apex_url/staging_url untouched; cas $CAS; values never printed)"
    # The base pair rides jq's environment (never argv) when it is carried over.
    CODE=$(EXISTING="$EXISTING" jq -c --argjson cas "$CAS" \
      '{options: {cas: $cas}, data: ((env.EXISTING|fromjson) + {govgraph_apex_url: .govgraphprobes.apex_url, govgraph_staging_url: .govgraphprobes.staging_url})}' <<<"$P" \
      | curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' -X POST --data-binary @- "$ADDR/v1/secret/data/$KV")
    [[ "$CODE" == "200" || "$CODE" == "204" ]] \
      || { echo "ERROR: PATCHing secret/$KV failed (HTTP $CODE; a check-and-set mismatch means another writer raced this run - re-run it)" >&2; exit 1; }
  fi
  curl -q -s --config "$CFG" "$ADDR/v1/secret/data/$KV" \
    | EXISTING="$EXISTING" jq -e \
      '(.data.data | (keys | sort) == ["apex_url","govgraph_apex_url","govgraph_staging_url","staging_url"])
       and (.data.data.apex_url == (env.EXISTING|fromjson).apex_url)
       and (.data.data.staging_url == (env.EXISTING|fromjson).staging_url)' >/dev/null \
    || { echo "ERROR: secret/$KV does not hold both govgraph probe URLs with apex_url/staging_url intact" >&2; exit 1; }
  if [[ "$HASPAIR" == true && "$OVER" != "true" ]]; then
    curl -q -s --config "$CFG" "$ADDR/v1/secret/data/$KV" \
      | jq -e '.data.data.govgraph_apex_url | length > 0' >/dev/null \
      || { echo "ERROR: govgraph_apex_url in secret/$KV is empty" >&2; exit 1; }
    echo "    [remote] kept (existing govgraph probe URLs; apex_url/staging_url untouched)"
  else
    AN=$(jq -r '.govgraphprobes.apex_nchars' <<<"$P")
    SN=$(jq -r '.govgraphprobes.staging_nchars' <<<"$P")
    curl -q -s --config "$CFG" "$ADDR/v1/secret/data/$KV" \
      | jq -e --argjson a "$AN" --argjson s "$SN" \
        '((.data.data.govgraph_apex_url | length) == $a)
         and ((.data.data.govgraph_staging_url | length) == $s)' >/dev/null \
      || { echo "ERROR: govgraph probe URLs in secret/$KV are not the prompted lengths" >&2; exit 1; }
    echo "    [remote] stored (govgraph apex $AN chars, staging $SN chars; apex_url/staging_url untouched)"
  fi
  echo "    [remote] govgraph-probes setup complete"
elif [[ "$MODE" == "watchdog" ]]; then
  # PATCH only watchdog_url on the existing SMTP secret. Never rewrite username/password/from/to.
  KV=monitoring/alertmanager
  echo "    [remote] reading existing secret/$KV (SMTP fields must already exist)"
  HTTP=$(curl -q -s --config "$CFG" -o "$CFG.body" -w '%{http_code}' "$ADDR/v1/secret/data/$KV")
  [[ "$HTTP" == "200" ]] || { echo "ERROR: secret/$KV missing (HTTP $HTTP) - run root-run alertmanager first" >&2; rm -f "$CFG.body"; exit 1; }
  EXISTING=$(jq -c '.data.data' "$CFG.body")
  rm -f "$CFG.body"
  echo "$EXISTING" | jq -e 'has("username") and has("password") and has("from") and has("to")' >/dev/null \
    || { echo "ERROR: secret/$KV is missing SMTP keys; refusing to patch" >&2; exit 1; }
  NCHARS=$(jq -r '.watchdog.nchars' <<<"$P")
  CODE=$(EXISTING="$EXISTING" jq -c '{data: ((env.EXISTING|fromjson) + {watchdog_url: .watchdog.url})}' <<<"$P" \
    | curl -q -s --config "$CFG" -o /dev/null -w '%{http_code}' -X POST --data-binary @- "$ADDR/v1/secret/data/$KV")
  [[ "$CODE" == "200" || "$CODE" == "204" ]] \
    || { echo "ERROR: patching secret/$KV watchdog_url failed (HTTP $CODE)" >&2; exit 1; }
  curl -q -s --config "$CFG" "$ADDR/v1/secret/data/$KV" \
    | jq -e --argjson n "$NCHARS" \
      '(.data.data | has("watchdog_url") and has("username") and has("password") and has("from") and has("to"))
       and ((.data.data.watchdog_url | length) == $n)' >/dev/null \
    || { echo "ERROR: watchdog_url missing or length mismatch after write" >&2; exit 1; }
  echo "    [remote] stored ($NCHARS chars)"
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
  # SMTP keys required. watchdog_url may already have been PATCHed by root-run watchdog-url.
  curl -q -s --config "$CFG" "$ADDR/v1/secret/data/$KV" \
    | jq -e '.data.data
        | (has("from") and has("password") and has("to") and has("username"))
        and ((keys - ["from","password","to","username","watchdog_url"]) | length == 0)' >/dev/null \
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
    PAYLOAD="$payload" jq -cn --argjson overwrite "$overwrite" \
    '(env.PAYLOAD|fromjson) + {smtp: {username: env.SMTP_USERNAME, from: env.SMTP_FROM, to: env.SMTP_TO, password: env.SMTP_PASSWORD}, overwrite: $overwrite}'
  unset p
}

# Hidden prompt for the healthchecks.io ping URL. Prefix-checked here so a bad value
# never reaches OpenBao. Stdout is ONLY the payload JSON (this runs inside $( )).
# Reads the k8s-pull password from the nexus VM (root 0600 file) over ssh into a local variable and
# extends the payload. Never printed, never argv. BREAKGLASS_NEXUS_PULL_CMD overrides the fetch (tests).
nexuspull_fetch_and_extend() {  # $1 payload-so-far -> full payload on stdout
  local payload="$1" pw
  echo "==> reading the k8s-pull password from nexus (never printed; never argv)" >&2
  pw=$(${BREAKGLASS_NEXUS_PULL_CMD:-ssh -n -o BatchMode=yes tunsadmin@192.168.1.87 sudo -n cat /etc/nexus/secrets/k8s-pull})
  pw="${pw%$'\n'}"
  [[ -n "$pw" ]] || die "empty k8s-pull password from nexus (nothing stored)"
  NEXUS_PULL_PW="$pw" PAYLOAD="$payload" jq -cn --argjson o "$( [[ "$OVERWRITE" == true ]] && echo true || echo false )" \
    '(env.PAYLOAD|fromjson) + {nexuspull: {username: "k8s-pull", password: env.NEXUS_PULL_PW}, overwrite: $o}'
  unset pw NEXUS_PULL_PW
}

# Hidden prompt for a Cloudflare remotely-managed tunnel token. Shape-checked locally so a
# paste of an unseal share or OpenBao token never reaches the store. A connector token is
# NOT a JWT: it is ONE standard-base64 blob of JSON {"a": account tag, "t": tunnel UUID,
# "s": secret, optional "e"} (cloudflared connection/connection.go TunnelToken.Encode,
# verified against 2026.10.7). Decoded and checked locally, exit code only - nothing is
# printed. Stdout is ONLY the payload JSON.
cloudflared_prompt_and_extend() {  # $1 payload-so-far -> full payload on stdout
  local payload="$1" tok
  echo "==> Cloudflare Tunnel token (never printed; never argv)" >&2
  if [[ -t 0 ]]; then
    read -rs -p "    token (hidden): " tok
    echo >&2
  else
    IFS= read -r tok
  fi
  tok="${tok//[$' \t\r\n']/}"
  [[ -n "$tok" ]] || die "tunnel token must not be empty"
  [[ "$tok" == eyJ* ]] || die "tunnel token must start with eyJ (base64 of a JSON object; nothing stored)"
  [[ "$tok" != *.*.* ]] || die "that looks like a JWT, not a Cloudflare tunnel token (copy the value after --token; nothing stored)"
  CF_TUNNEL_TOKEN="$tok" python3 -I -c '
import base64, binascii, json, os, sys, uuid
t = os.environ["CF_TUNNEL_TOKEN"]
try:
    d = json.loads(base64.b64decode(t + "=" * (-len(t) % 4), validate=True))
    ok = (isinstance(d, dict) and isinstance(d.get("a"), str) and len(d["a"]) > 0
          and isinstance(d.get("s"), str) and len(d["s"]) > 0
          and isinstance(d.get("t"), str) and bool(uuid.UUID(d["t"])))
except (binascii.Error, ValueError, TypeError):
    ok = False
sys.exit(0 if ok else 1)
' || die "tunnel token must decode to Cloudflare's {a, t, s} JSON (account, tunnel UUID, secret; nothing stored)"
  local overwrite=false
  [[ "$OVERWRITE" == true ]] && overwrite=true
  local nchars=${#tok}
  CF_TUNNEL_TOKEN="$tok" \
    PAYLOAD="$payload" jq -cn --argjson n "$nchars" --argjson overwrite "$overwrite" \
      '(env.PAYLOAD|fromjson) + {cloudflared: {tunnel_token: env.CF_TUNNEL_TOKEN, nchars: $n}, overwrite: $overwrite}'
  unset tok CF_TUNNEL_TOKEN
}

# Hidden prompts for the two public-path HTTPS URLs blackbox will probe. Shape-checked
# locally so a LAN IP, http://, or a credential-shaped paste never reaches the store.
# Stdout is ONLY the payload JSON. Values are never printed.
publicsite_prompt_and_extend() {  # $1 payload-so-far -> full payload on stdout
  local payload="$1" apex staging
  echo "==> public-path probe URLs (never printed; never argv)" >&2
  if [[ -t 0 ]]; then
    read -rs -p "    apex URL (hidden, expect 200): " apex
    echo >&2
    read -rs -p "    staging URL (hidden, expect 302): " staging
    echo >&2
  else
    IFS= read -r apex
    IFS= read -r staging
  fi
  apex="${apex//[$' \t\r\n']/}"
  staging="${staging//[$' \t\r\n']/}"
  [[ -n "$apex" && -n "$staging" ]] || die "both probe URLs must be non-empty"
  PUBLICSITE_URL="$apex" python3 -I -c '
import ipaddress, os, sys
from urllib.parse import urlparse
u = os.environ["PUBLICSITE_URL"]
if not u.startswith("https://"):
    sys.exit(1)
p = urlparse(u)
if p.scheme != "https" or not p.netloc or p.username or p.password:
    sys.exit(1)
host = p.hostname or ""
if "." not in host:
    sys.exit(1)
try:
    ipaddress.ip_address(host)
    sys.exit(1)
except ValueError:
    pass
' || die "apex URL must be https://<hostname>/... with a DNS name, not an IP (nothing stored)"
  PUBLICSITE_URL="$staging" python3 -I -c '
import ipaddress, os, sys
from urllib.parse import urlparse
u = os.environ["PUBLICSITE_URL"]
if not u.startswith("https://"):
    sys.exit(1)
p = urlparse(u)
if p.scheme != "https" or not p.netloc or p.username or p.password:
    sys.exit(1)
host = p.hostname or ""
if "." not in host:
    sys.exit(1)
try:
    ipaddress.ip_address(host)
    sys.exit(1)
except ValueError:
    pass
' || die "staging URL must be https://<hostname>/... with a DNS name, not an IP (nothing stored)"
  local overwrite=false
  [[ "$OVERWRITE" == true ]] && overwrite=true
  PUBLICSITE_APEX="$apex" PUBLICSITE_STAGING="$staging" \
    PAYLOAD="$payload" jq -cn --argjson overwrite "$overwrite" \
      --argjson an "${#apex}" --argjson sn "${#staging}" \
      '(env.PAYLOAD|fromjson) + {publicsite: {apex_url: env.PUBLICSITE_APEX, staging_url: env.PUBLICSITE_STAGING, apex_nchars: $an, staging_nchars: $sn}, overwrite: $overwrite}'
  unset apex staging PUBLICSITE_APEX PUBLICSITE_STAGING PUBLICSITE_URL
}

# Hidden prompts for the govgraph tenant secrets. DATABASE_URL is shape-checked locally
# (postgres scheme, a host, port 5432/6543) without ever echoing any part of it; internal
# whitespace is rejected, only leading/trailing whitespace is trimmed (a bad paste is
# refused, never silently stored as a different value). Prod also prompts hidden for
# CF_ZONE_ID (32 hex) and CF_API_TOKEN (non-empty, no internal whitespace). CRON_SECRET is
# NOT prompted: it is generated on sectools by the remote step. Values travel local
# variable -> jq environment -> ssh stdin payload, never argv, and are never printed.
# Stdout is ONLY the payload JSON (this runs inside $( )).
govgraph_prompt_and_extend() {  # $1 payload-so-far, $2 staging|prod -> full payload on stdout
  local payload="$1" envn="$2" db zone token ov_app=false ov_cf=false
  [[ "$OVERWRITE" == true || "$OVERWRITE_APP" == true ]] && ov_app=true
  [[ "$OVERWRITE" == true || "$OVERWRITE_CF" == true ]] && ov_cf=true
  echo "==> govgraph $envn secrets (never printed; never argv)" >&2
  if [[ -t 0 ]]; then
    read -rs -p "    DATABASE_URL (hidden): " db
    echo >&2
  else
    IFS= read -r db
  fi
  # Trim only leading/trailing whitespace: internal whitespace means a bad paste - refuse.
  db="${db#"${db%%[![:space:]]*}"}"
  db="${db%"${db##*[![:space:]]}"}"
  [[ -n "$db" ]] || die "DATABASE_URL must not be empty (nothing stored)"
  [[ "$db" != *[[:space:]]* ]] || die "DATABASE_URL must not contain whitespace (nothing stored)"
  # Every parse happens inside the try with a bare exit 1: a password with an unencoded
  # '/', '?' or '#' makes urlparse raise on attribute access, and its ValueError would
  # otherwise name the offending fragment. Nothing is printed on any path.
  GOV_DATABASE_URL="$db" python3 -I -c '
import os, sys
from urllib.parse import urlparse
u = os.environ["GOV_DATABASE_URL"]
ok = False
if u.startswith("postgres://") or u.startswith("postgresql://"):
    try:
        p = urlparse(u)
        ok = bool(p.netloc and p.hostname) and p.port in (5432, 6543)
    except Exception:
        ok = False
sys.exit(0 if ok else 1)
' || die "DATABASE_URL must be postgres:// or postgresql:// with a host and port 5432 or 6543 (nothing stored)"
  if [[ "$envn" == "prod" ]]; then
    if [[ -t 0 ]]; then
      read -rs -p "    CF_ZONE_ID (hidden, 32 hex characters): " zone
      echo >&2
      read -rs -p "    CF_API_TOKEN (hidden): " token
      echo >&2
    else
      IFS= read -r zone
      IFS= read -r token
    fi
    zone="${zone#"${zone%%[![:space:]]*}"}"
    zone="${zone%"${zone##*[![:space:]]}"}"
    [[ "$zone" =~ ^[0-9a-fA-F]{32}$ ]] || die "CF_ZONE_ID must be 32 hex characters (nothing stored)"
    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    [[ -n "$token" ]] || die "CF_API_TOKEN must not be empty (nothing stored)"
    [[ "$token" != *[[:space:]]* ]] || die "CF_API_TOKEN must not contain whitespace (nothing stored)"
    GOV_DATABASE_URL="$db" GOV_ZONE_ID="$zone" GOV_API_TOKEN="$token" \
      PAYLOAD="$payload" jq -cn --arg e "$envn" --argjson ov_app "$ov_app" --argjson ov_cf "$ov_cf" \
        '(env.PAYLOAD|fromjson) + {govgraph: {env: $e, database_url: env.GOV_DATABASE_URL, zone_id: env.GOV_ZONE_ID, api_token: env.GOV_API_TOKEN, overwrite_app: $ov_app, overwrite_cf: $ov_cf}}'
    unset zone token
  else
    GOV_DATABASE_URL="$db" \
      PAYLOAD="$payload" jq -cn --arg e "$envn" --argjson ov_app "$ov_app" --argjson ov_cf "$ov_cf" \
        '(env.PAYLOAD|fromjson) + {govgraph: {env: $e, database_url: env.GOV_DATABASE_URL, overwrite_app: $ov_app, overwrite_cf: $ov_cf}}'
  fi
  unset db
}

# Hidden prompts for the two govgraph public-path probe URLs. Same shape rules as
# publicsite_prompt_and_extend (https, a DNS hostname, no embedded credentials) plus a
# required trailing slash (the runbook's canonical probe paths end in /). Stdout is ONLY
# the payload JSON. Values are never printed, never argv; the remote step PATCHes them
# into the shared monitoring/public-site-probes object.
govgraphprobes_prompt_and_extend() {  # $1 payload-so-far -> full payload on stdout
  local payload="$1" apex staging overwrite=false
  [[ "$OVERWRITE" == true ]] && overwrite=true
  echo "==> govgraph probe URLs (never printed; never argv)" >&2
  if [[ -t 0 ]]; then
    read -rs -p "    govgraph apex URL (hidden, https, trailing slash): " apex
    echo >&2
    read -rs -p "    govgraph staging URL (hidden, https, trailing slash): " staging
    echo >&2
  else
    IFS= read -r apex
    IFS= read -r staging
  fi
  apex="${apex#"${apex%%[![:space:]]*}"}"
  apex="${apex%"${apex##*[![:space:]]}"}"
  staging="${staging#"${staging%%[![:space:]]*}"}"
  staging="${staging%"${staging##*[![:space:]]}"}"
  [[ -n "$apex" && -n "$staging" ]] || die "both probe URLs must be non-empty (nothing stored)"
  [[ "$apex" != *[[:space:]]* && "$staging" != *[[:space:]]* ]] \
    || die "probe URLs must not contain internal whitespace (nothing stored)"
  [[ "$apex" == */ && "$staging" == */ ]] \
    || die "both probe URLs must end in a slash (the canonical probe paths; nothing stored)"
  for u in "$apex" "$staging"; do
    GOV_PS_URL="$u" python3 -I -c '
import ipaddress, os, sys
from urllib.parse import urlparse
u = os.environ["GOV_PS_URL"]
if not u.startswith("https://"):
    sys.exit(1)
p = urlparse(u)
if p.scheme != "https" or not p.netloc or p.username or p.password:
    sys.exit(1)
host = p.hostname or ""
if "." not in host:
    sys.exit(1)
try:
    ipaddress.ip_address(host)
    sys.exit(1)
except ValueError:
    pass
' || die "each probe URL must be https://<hostname>/... with a DNS name, not an IP (nothing stored)"
  done
  GOV_PS_APEX="$apex" GOV_PS_STAGING="$staging" \
    PAYLOAD="$payload" jq -cn --argjson overwrite "$overwrite" \
      --argjson an "${#apex}" --argjson sn "${#staging}" \
      '(env.PAYLOAD|fromjson) + {govgraphprobes: {apex_url: env.GOV_PS_APEX, staging_url: env.GOV_PS_STAGING, apex_nchars: $an, staging_nchars: $sn}, overwrite: $overwrite}'
  unset apex staging GOV_PS_APEX GOV_PS_STAGING GOV_PS_URL
}

watchdog_prompt_and_extend() {  # $1 payload-so-far -> full payload on stdout
  local payload="$1" url
  echo "==> healthchecks.io ping URL (never printed; never argv)" >&2
  if [[ -t 0 ]]; then
    read -rs -p "    URL (hidden): " url
    echo >&2
  else
    IFS= read -r url
  fi
  [[ -n "$url" ]] || die "watchdog URL must not be empty"
  [[ "$url" == https://hc-ping.com/* ]] \
    || die "watchdog URL must start with https://hc-ping.com/ (nothing stored)"
  local nchars=${#url}
  WATCHDOG_URL="$url" \
    PAYLOAD="$payload" jq -cn --argjson n "$nchars" \
      '(env.PAYLOAD|fromjson) + {watchdog: {url: env.WATCHDOG_URL, nchars: $n}}'
  unset url WATCHDOG_URL
}

# Prompts for the Gitea OAuth2 app credentials locally (both hidden: the client id is not
# secret, but typing it blind avoids shoulder-surfing and keeps the flow uniform) and
# extends the payload. Same stderr rule as alertmanager_prompt_and_extend: this runs inside
# $( ), so stdout must carry ONLY the payload JSON.
oidc_prompt_and_extend() {   # $1 payload-so-far, $2 consumer -> full payload on stdout
  local payload="$1" consumer="$2" cid csec overwrite=false
  [[ "$OVERWRITE" == true ]] && overwrite=true
  echo "==> Gitea OAuth2 app credentials for consumer '${consumer}' (ADR 0016 decision 8)" >&2
  read -rs -p "    Client ID (input hidden): " cid
  echo >&2
  [[ -n "$cid" ]] || die "client id must not be empty"
  read -rs -p "    Client Secret (input hidden): " csec
  echo >&2
  [[ -n "$csec" ]] || die "client secret must not be empty"
  # The values reach jq through its environment (allowed), never argv; they then travel to
  # sectools inside the payload on ssh stdin. The oauth2-proxy cookie secret is NOT here:
  # it is generated on sectools, so it never touches the Mac at all.
  OIDC_CLIENT_ID="$cid" OIDC_CLIENT_SECRET="$csec" \
    PAYLOAD="$payload" jq -cn --arg c "$consumer" --argjson overwrite "$overwrite" \
      '(env.PAYLOAD|fromjson) + {oidc: {consumer: $c, client_id: env.OIDC_CLIENT_ID, client_secret: env.OIDC_CLIENT_SECRET}, overwrite: $overwrite}'
  unset csec
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
