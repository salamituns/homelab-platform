#!/usr/bin/env bash
# Open a belleshop-deploy PR with the signed image digests (ADR 0012).
# Jenkins calls this on main only. CI never pushes to the branch Argo CD syncs.

# shellcheck source=lib.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
	printf '%s\n' "usage: promote.sh <digests.txt>" >&2
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi
[[ $# -eq 1 ]] || {
	usage
	exit 1
}

digests="$1"
[[ -f "${digests}" ]] || ci_die "missing ${digests}"

ci_require_cmd curl
ci_require_cmd git
ci_require_cmd python3
if [[ -z "${KUSTOMIZE_CMD:-}" ]]; then
	ci_require_cmd docker
fi

[[ -n "${IMAGE_TAG:-}" ]] || ci_die "IMAGE_TAG is unset"
[[ -n "${GITEA_PROMOTE_USER:-}" ]] || ci_die "GITEA_PROMOTE_USER is unset"

# Credential files from Jenkins end in a newline. Inside a curl -K header that
# newline splits the config line and the request goes out unauthenticated.
PROMOTE_TOKEN="$(printf '%s' "${GITEA_PROMOTE_TOKEN-}" | tr -d '\r\n')"
[[ -n "${PROMOTE_TOKEN}" ]] || ci_die "promote token is unset"
export PROMOTE_TOKEN
export GITEA_PROMOTE_USER

BACKEND_REF="$(awk -F= '/^belleshop-backend=/{print $2}' "${digests}")"
FRONTEND_REF="$(awk -F= '/^belleshop-frontend=/{print $2}' "${digests}")"
[[ -n "${BACKEND_REF}" && -n "${FRONTEND_REF}" ]] || ci_die "digests.txt missing backend or frontend ref"

GITEA_URL="${GITEA_URL:-https://gitea.home.arpa}"
GITEA_URL="${GITEA_URL%/}"

GITEA_OWNER="$(python3 - <<'PY'
import os, sys
from urllib.parse import urlparse

raw = os.environ.get("GIT_URL") or ""
if not raw:
    sys.exit("GIT_URL is unset; cannot derive Gitea owner")
parsed = urlparse(raw)
if parsed.scheme == "https" and parsed.hostname == "gitea.home.arpa":
    parts = [p for p in parsed.path.strip("/").split("/") if p]
elif raw.startswith("git@gitea.home.arpa:"):
    parts = [p for p in raw.split(":", 1)[1].strip().strip("/").split("/") if p]
else:
    sys.exit("GIT_URL is not https://gitea.home.arpa/... ; refusing to guess the owner")
if len(parts) < 2:
    sys.exit("GIT_URL path does not contain owner/repo")
print(parts[0])
PY
)" || ci_die "could not derive Gitea owner from GIT_URL"
[[ -n "${GITEA_OWNER}" ]] || ci_die "empty Gitea owner"

PROMOTE_REMOTE="${PROMOTE_REMOTE:-${GITEA_URL}/${GITEA_OWNER}/belleshop-deploy.git}"
KUSTOMIZE_IMAGE="${KUSTOMIZE_IMAGE:-registry.k8s.io/kustomize/kustomize:v5.8.3@sha256:429eda4a1c76a7de458d0c4ca3ded9b5d764899ff6bdaeccc1d98b1b6ee873e4}"
api="${GITEA_URL}/api/v1/repos/${GITEA_OWNER}/belleshop-deploy/pulls"

# curl -K reads the header from stdin so the token is not in argv / ps.
gitea_api() {
	printf 'header = "Authorization: token %s"\n' "${PROMOTE_TOKEN}" | curl -q -K - "$@"
}

askpass="$(mktemp "${TMPDIR:-/tmp}/promote-askpass.XXXXXX")"
cleanup_askpass() { rm -f "${askpass}"; }
trap cleanup_askpass EXIT
cat >"${askpass}" <<'EOF'
#!/bin/sh
case "$1" in
*[Uu]sername*) printf '%s\n' "${GITEA_PROMOTE_USER}" ;;
*) printf '%s\n' "${PROMOTE_TOKEN}" ;;
esac
EOF
chmod 700 "${askpass}"

git_auth() {
	# Token stays in the environment (GIT_ASKPASS). Never in a URL or git argv.
	GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="${askpass}" git -c credential.helper= "$@"
}

overlay_ref() {
	python3 - "$1" overlays/dev/kustomization.yaml <<'PY'
import sys

want, path = sys.argv[1], sys.argv[2]
name = new = digest = None
found = None
for raw in open(path, encoding="utf-8"):
	line = raw.strip()
	if line.startswith("- name:") or line.startswith("name:"):
		if name == want and new and digest:
			found = f"{new}@{digest}"
		name = line.split(":", 1)[1].strip()
		new = digest = None
	elif line.startswith("newName:"):
		new = line.split(":", 1)[1].strip()
	elif line.startswith("digest:"):
		digest = line.split(":", 1)[1].strip()
if name == want and new and digest:
	found = f"{new}@{digest}"
print(found or "")
PY
}

run_kustomize() {
	if [[ -n "${KUSTOMIZE_CMD:-}" ]]; then
		(cd overlays/dev && "${KUSTOMIZE_CMD}" edit set image "$@")
	else
		docker run --rm \
			--user "$(id -u):$(id -g)" \
			-v "$(pwd):/work" \
			-w /work/overlays/dev \
			"${KUSTOMIZE_IMAGE}" \
			edit set image "$@"
	fi
}

ci_log "promote: IMAGE_TAG=${IMAGE_TAG}"

rm -rf belleshop-deploy
GIT_TERMINAL_PROMPT=0 git_auth clone "${PROMOTE_REMOTE}" belleshop-deploy
cd belleshop-deploy || ci_die "clone did not create belleshop-deploy"

BRANCH="promote/${IMAGE_TAG}"
if ! git_auth fetch origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}"; then
	ci_log "promote: no existing ${BRANCH} on remote"
fi
if git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; then
	git checkout -B "${BRANCH}" "origin/${BRANCH}"
else
	git checkout -B "${BRANCH}" origin/main
fi

if [[ "$(overlay_ref belleshop-backend)" == "${BACKEND_REF}" && "$(overlay_ref belleshop-frontend)" == "${FRONTEND_REF}" ]]; then
	ci_log "overlay already pins these digests; skip empty PR"
	exit 0
fi

run_kustomize \
	"belleshop-backend=${BACKEND_REF}" \
	"belleshop-frontend=${FRONTEND_REF}"

git add overlays/dev/kustomization.yaml
if git diff --cached --quiet; then
	ci_log "kustomize wrote no change; skip empty PR"
	exit 0
fi

git -c user.name=ci-promote -c user.email=ci-promote@home.arpa \
	commit -m "promote belleshop ${IMAGE_TAG}"
GIT_TERMINAL_PROMPT=0 git_auth push -u origin "${BRANCH}"

pulls_body="$(mktemp "${TMPDIR:-/tmp}/promote-pulls.XXXXXX")"
pulls_code="$(gitea_api -sS -o "${pulls_body}" -w '%{http_code}' \
	"${api}?state=open&limit=50")"
if [[ "${pulls_code}" != 200 ]]; then
	ci_log "list PRs HTTP ${pulls_code}"
	cat "${pulls_body}" >&2
	exit 1
fi
existing="$(python3 - "${BRANCH}" "${pulls_body}" <<'PY'
import json, sys

branch, path = sys.argv[1], sys.argv[2]
for pr in json.load(open(path, encoding="utf-8")):
	if pr.get("head", {}).get("ref") == branch:
		print(pr["number"])
		break
PY
)"
if [[ -n "${existing}" ]]; then
	ci_log "PR #${existing} already open for ${BRANCH}; branch updated"
	exit 0
fi

pr_json="$(mktemp "${TMPDIR:-/tmp}/promote-pr.XXXXXX")"
python3 - "${IMAGE_TAG}" "${BACKEND_REF}" "${FRONTEND_REF}" "${pr_json}" <<'PY'
import json, os, sys

tag, backend, frontend, path = sys.argv[1:5]
body = (
	f"backend: `{backend}`\n"
	f"frontend: `{frontend}`\n"
	f"BelleShop commit: `{os.environ.get('GIT_COMMIT', '')}`\n"
	f"Jenkins: {os.environ.get('BUILD_URL', '')}\n"
)
payload = {
	"title": f"promote belleshop {tag}",
	"head": f"promote/{tag}",
	"base": "main",
	"body": body,
}
with open(path, "w", encoding="utf-8") as fh:
	json.dump(payload, fh)
PY

create_body="$(mktemp "${TMPDIR:-/tmp}/promote-create.XXXXXX")"
# JSON is a file, not stdin: stdin is already the curl -K config.
create_code="$(gitea_api -sS -o "${create_body}" -w '%{http_code}' \
	-H "Content-Type: application/json" \
	--data-binary "@${pr_json}" \
	"${api}")"
case "${create_code}" in
201)
	ci_log "opened promotion PR"
	;;
409 | 422)
	if grep -qi 'already exists' "${create_body}"; then
		ci_log "PR already exists (HTTP ${create_code}); branch updated"
	else
		ci_log "create PR HTTP ${create_code}"
		cat "${create_body}" >&2
		exit 1
	fi
	;;
*)
	ci_log "create PR HTTP ${create_code}"
	cat "${create_body}" >&2
	exit 1
	;;
esac
