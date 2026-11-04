#!/usr/bin/env bash
# Owner-run Argo CD native OIDC apply (ADR 0016 step 2, v3.5.1).
# Runs on the Mac; mutates the cluster only when you omit --dry-run.
# The agent must never run this without --dry-run.
#
# Why stdin + merge-patch: the client secret must not appear on argv (ps);
# kubectl replace of argocd-cm would drop live resource.exclusions.
# Why no kubectl rollout: v3.5.1 watchSettings logs "oidc config modified.
# restarting" / "url modified. restarting" and sends GracefulRestartSignal
# (in-process). RBAC reloads via the informer (policy.default / policy.csv /
# scopes). Dex is left running; OIDCConfigRAW skips the Dex rewrite path.
#
# Usage:
#   scripts/argocd-oidc-apply.sh --dry-run
#   scripts/argocd-oidc-apply.sh                 # apply (prompts for client id+secret)
#   scripts/argocd-oidc-apply.sh --rollback      # kubectl replace from a backup dir
#
# Env:
#   SSH_HOST                 default Master
#   REMOTE_KUBECTL           default: sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf
#   BACKUP_ROOT              default ~/homelab-platform/private
#   BACKUP_DIR               for --rollback; default latest argocd-backup-* under BACKUP_ROOT
#   ARGOCD_OIDC_CLIENT_ID    skip prompt on apply
#   ARGOCD_OIDC_CLIENT_SECRET
#   SKIP_OPENBAO_PROMPT=1    skip the OpenBao reminder on apply
set -euo pipefail
# Never print secrets if someone traces.
set +o xtrace
export PS4=''

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OIDC_DIR="$REPO_ROOT/k8s/platform/argocd-oidc"
CA_FILE="$REPO_ROOT/ansible/files/ca/gitea-caddy-root.crt"
SSH_HOST="${SSH_HOST:-Master}"
REMOTE_KUBECTL="${REMOTE_KUBECTL:-sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/homelab-platform/private}"
NS=argocd
MODE=apply
BACKUP_DIR="${BACKUP_DIR:-}"

usage() {
  echo "usage: $0 [--dry-run | --rollback]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE=dry-run; shift ;;
    --rollback) MODE=rollback; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

remote() {
  # shellcheck disable=SC2029
  ssh -o BatchMode=yes "$SSH_HOST" "$REMOTE_KUBECTL $*"
}

remote_stdin() {
  local args="$1"
  # Patch/replace payload on stdin, never argv.
  # shellcheck disable=SC2029
  ssh -o BatchMode=yes "$SSH_HOST" "$REMOTE_KUBECTL $args"
}

need() {
  [[ -e "$1" ]] || { echo "error: missing $1" >&2; exit 1; }
}

need "$OIDC_DIR/oidc.config.yaml"
need "$OIDC_DIR/argocd-rbac-cm.yaml"
need "$CA_FILE"
command -v python3 >/dev/null || { echo "error: python3 required" >&2; exit 1; }
command -v openssl >/dev/null || { echo "error: openssl required" >&2; exit 1; }

# Prove oidc.config.rootCA is the same cert as the vendored Gitea Caddy root
# (Grafana lesson: the wrong CA / a file-as-dir mount is silent until login).
ca_fp="$(openssl x509 -in "$CA_FILE" -noout -fingerprint -sha256 | awk -F= '{print $2}')"
tmp_pem="$(mktemp)"
trap 'rm -f "$tmp_pem"' EXIT
python3 - "$OIDC_DIR/oidc.config.yaml" "$tmp_pem" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
start = text.find("-----BEGIN CERTIFICATE-----")
end = text.find("-----END CERTIFICATE-----")
if start < 0 or end < 0:
    sys.exit("oidc.config.yaml has no PEM")
block = text[start:end + len("-----END CERTIFICATE-----")]
# YAML indent would make openssl reject the PEM.
pem = "\n".join(line.strip() for line in block.splitlines()) + "\n"
Path(sys.argv[2]).write_text(pem)
PY
cfg_fp="$(openssl x509 -in "$tmp_pem" -noout -fingerprint -sha256 | awk -F= '{print $2}')"
if [[ "$ca_fp" != "$cfg_fp" ]]; then
  echo "error: oidc.config.yaml rootCA fingerprint != $CA_FILE" >&2
  echo "  vendored: $ca_fp" >&2
  echo "  config:   $cfg_fp" >&2
  exit 1
fi

cm_patch_json() {
  python3 - "$OIDC_DIR/oidc.config.yaml" <<'PY'
import json, pathlib, sys
oidc = pathlib.Path(sys.argv[1]).read_text()
# Drop comment-only header lines so yaml.Unmarshal in argocd sees the mapping.
body_lines = []
started = False
for line in oidc.splitlines(True):
    if not started and (line.startswith("#") or line.strip() == ""):
        continue
    started = True
    body_lines.append(line)
print(json.dumps({
    "data": {
        "url": "https://argocd.apps.home.arpa",
        "admin.enabled": "true",
        "oidc.config": "".join(body_lines),
    }
}))
PY
}

rbac_patch_json() {
  python3 - <<'PY'
import json
csv = """g, homelab:platform-admins, role:admin
g, homelab, role:readonly
"""
# Keep in lockstep with argocd-rbac-cm.yaml data.policy.csv
print(json.dumps({
    "data": {
        "policy.default": "",
        "scopes": "[groups]",
        "policy.csv": csv,
    }
}))
PY
}

merge_diff() {
  local kind="$1" name="$2" patch_json="$3"
  local live merged
  live="$(mktemp)"
  merged="$(mktemp)"
  echo "--- kubectl diff $kind/$name (merge data keys; live object from $SSH_HOST) ---"
  remote "get $kind $name -n $NS -o json" >"$live"
  python3 -c 'import json,sys
raw=sys.stdin.read()
if not raw.strip():
    sys.exit("empty kubectl get (ssh/json)")
live=json.loads(raw)
patch=json.loads(sys.argv[1])
data=live.get("data") or {}
data.update(patch.get("data") or {})
live["data"]=data
md=live.get("metadata") or {}
md.pop("managedFields", None)
live["metadata"]=md
json.dump(live, sys.stdout)
' "$patch_json" <"$live" >"$merged"
  # kubectl diff exits 1 when the live object would change.
  remote_stdin "diff -n $NS -f -" <"$merged" || true
  rm -f "$live" "$merged"
}

backup_objects() {
  local dest="$1"
  mkdir -p "$dest"
  chmod 700 "$dest"
  umask 077
  remote "get cm argocd-cm -n $NS -o yaml" >"$dest/argocd-cm.yaml"
  remote "get cm argocd-rbac-cm -n $NS -o yaml" >"$dest/argocd-rbac-cm.yaml"
  remote "get secret argocd-secret -n $NS -o yaml" >"$dest/argocd-secret.yaml"
  chmod 600 "$dest"/*.yaml
  echo "backup: $dest (mode 0700, yaml 0600)"
}

latest_backup() {
  local latest=""
  latest="$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'argocd-backup-*' 2>/dev/null | sort | tail -n 1 || true)"
  [[ -n "$latest" ]] || { echo "error: no $BACKUP_ROOT/argocd-backup-* found" >&2; exit 1; }
  printf '%s' "$latest"
}

if [[ "$MODE" == rollback ]]; then
  [[ -n "$BACKUP_DIR" ]] || BACKUP_DIR="$(latest_backup)"
  echo "rollback from $BACKUP_DIR"
  for f in argocd-cm.yaml argocd-rbac-cm.yaml argocd-secret.yaml; do
    need "$BACKUP_DIR/$f"
  done
  for f in argocd-cm.yaml argocd-rbac-cm.yaml argocd-secret.yaml; do
    echo "replace $f"
    remote_stdin "replace -f -" <"$BACKUP_DIR/$f"
  done
  echo "replaced. v3.5.1 restarts the API server in-process on url/oidc change; wait for Ready:"
  echo "  ssh $SSH_HOST '$REMOTE_KUBECTL -n $NS wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server --timeout=120s'"
  exit 0
fi

echo "Argo CD OIDC apply (v3.5.1 keys; Gitea issuer https://gitea.home.arpa)"
echo "  url=https://argocd.apps.home.arpa  redirect=/auth/callback"
echo "  secret keys: oidc.gitea.clientID oidc.gitea.clientSecret"
echo "  Gitea Caddy root SHA256 fingerprint: $ca_fp"
echo "  dex-server: left running (OIDCConfigRAW skips Dex rewrite)"
echo "  no kubectl rollout (watchSettings GracefulRestartSignal)"

if [[ "$MODE" == dry-run ]]; then
  echo
  echo "dry-run: no cluster write, no secret prompt, no OpenBao write."
  echo "would backup to $BACKUP_ROOT/argocd-backup-<utc>/"
  echo "would merge-patch cm/argocd-cm keys: url, admin.enabled, oidc.config"
  echo "would merge-patch cm/argocd-rbac-cm keys: policy.default, scopes, policy.csv"
  echo "would merge-patch secret/argocd-secret keys: oidc.gitea.clientID, oidc.gitea.clientSecret (values not shown)"
  echo
  cm_patch_json
  echo
  rbac_patch_json
  echo
  merge_diff cm argocd-cm "$(cm_patch_json)"
  merge_diff cm argocd-rbac-cm "$(rbac_patch_json)"
  echo
  echo "first-run after apply (owner):"
  echo "  1. scripts/openbao-breakglass.sh root-run oidc argocd"
  echo "  2. this script without --dry-run"
  echo "  3. curl -q -sSI https://argocd.apps.home.arpa/auth/login | expect 302/303 to"
  echo "     https://gitea.home.arpa/login/oauth/authorize with"
  echo "     redirect_uri=https://argocd.apps.home.arpa/auth/callback"
  echo "  4. browser login as a homelab:platform-admins member; Applications list; local admin still works"
  echo "  5. ssh $SSH_HOST '$REMOTE_KUBECTL -n $NS logs -l app.kubernetes.io/name=argocd-server --tail=80'"
  echo "     expect 'oidc config modified. restarting' or 'url modified. restarting', then Ready"
  exit 0
fi

if [[ "${SKIP_OPENBAO_PROMPT:-}" != 1 ]]; then
  echo
  echo "OpenBao first: client id/secret must already be at secret/data/oidc/argocd"
  echo "  ssh sectools, then: sudo /root/homelab-platform/scripts/root-run oidc argocd"
  echo "  (or from this repo: scripts/openbao-breakglass.sh root-run oidc argocd)"
  echo "oidc-read does not grant ESO this path; you paste the values here over admin SSH."
  read -r -p "OpenBao record exists? type yes: " ans
  [[ "$ans" == yes ]] || { echo "abort: store the secret first" >&2; exit 1; }
fi

if [[ -z "${ARGOCD_OIDC_CLIENT_ID:-}" ]]; then
  read -r -s -p "Gitea OAuth client id: " ARGOCD_OIDC_CLIENT_ID
  echo
fi
if [[ -z "${ARGOCD_OIDC_CLIENT_SECRET:-}" ]]; then
  read -r -s -p "Gitea OAuth client secret: " ARGOCD_OIDC_CLIENT_SECRET
  echo
fi
[[ -n "$ARGOCD_OIDC_CLIENT_ID" && -n "$ARGOCD_OIDC_CLIENT_SECRET" ]] || {
  echo "error: empty client id or secret" >&2
  exit 1
}

ts="$(date -u +%Y%m%dT%H%M%SZ)"
dest="$BACKUP_ROOT/argocd-backup-$ts"
backup_objects "$dest"

secret_json="$(ARGOCD_OIDC_CLIENT_ID="$ARGOCD_OIDC_CLIENT_ID" ARGOCD_OIDC_CLIENT_SECRET="$ARGOCD_OIDC_CLIENT_SECRET" python3 - <<'PY'
import base64, json, os
def b64(k):
    return base64.b64encode(os.environ[k].encode()).decode()
print(json.dumps({"data": {
    "oidc.gitea.clientID": b64("ARGOCD_OIDC_CLIENT_ID"),
    "oidc.gitea.clientSecret": b64("ARGOCD_OIDC_CLIENT_SECRET"),
}}))
PY
)"
unset ARGOCD_OIDC_CLIENT_ID ARGOCD_OIDC_CLIENT_SECRET

printf '%s\n' "$secret_json" | remote_stdin "patch secret argocd-secret -n $NS --type merge --patch-file=/dev/stdin"
unset secret_json
cm_patch_json | remote_stdin "patch cm argocd-cm -n $NS --type merge --patch-file=/dev/stdin"
rbac_patch_json | remote_stdin "patch cm argocd-rbac-cm -n $NS --type merge --patch-file=/dev/stdin"

echo "patched. waiting for argocd-server Ready (in-process restart, no rollout)..."
remote "-n $NS wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server --timeout=120s" || true

echo
echo "verify redirect (expect 302/303 to gitea authorize + redirect_uri=.../auth/callback):"
echo "  curl -q -sSI https://argocd.apps.home.arpa/auth/login"
if command -v curl >/dev/null; then
  curl -q -sSI https://argocd.apps.home.arpa/auth/login | head -n 20 || true
fi
echo "rollback: $0 --rollback   # uses $dest unless BACKUP_DIR=..."
echo "backup: $dest"
