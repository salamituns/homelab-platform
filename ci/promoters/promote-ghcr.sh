#!/usr/bin/env bash
# GHCR -> lab promoter (ADR 0019 D4; personal-site since Phase 1, govgraph Phase 2 —
# per-app destinations and workflow are env, see GHCR_IMAGE / GHCR_WORKFLOW below).
#
# GitHub Actions builds the app (personal site, govgraph) and pushes it to GHCR, signed
# keyless with GitHub's OIDC (Fulcio cert, Rekor log). The lab does not trust GitHub's
# keyless identity for admission - Kyverno verifies the LAB Cosign key - so this script
# is what crosses the trust boundary, on a 15-minute timer, for images not a pipeline:
#
#   1. resolve ghcr.io/<owner>/<GHCR_IMAGE>:main to a digest (anonymous, package is public)
#   2. cosign verify: Fulcio issuer + workflow identity + repository claim must all
#      match <owner>/<repo>'s .github/workflows/<GHCR_WORKFLOW> on refs/heads/main
#   3. same again for the SPDX SBOM attestation (cosign verify-attestation)
#   4. Trivy re-scan of that exact digest (HIGH/CRITICAL with a fix available = stop)
#   5. crane copy into the per-app Nexus repo PRESERVING the digest
#   6. sign + attest that digest with the LAB key (gates/sign.sh)
#   7. open a PR in apps-deploy pinning the digest in the staging overlay
#      (digest already pinned = stop before 5, nothing written; production is a human PR)
#
# --dry-run stops after step 4: verify only, no copy, no sign, no PR.
#
# The GitHub repo name can contain a public domain (the personal site's does). It
# arrives via SOURCE_REPO (the per-app source-repo Jenkins credential) and is never
# printed: logs carry digests only, and tool output goes to ${REPORT_DIR} or is
# checked by exit code.

# Installed at /opt/ci-gates (flat, next to the gates) or run from ci/promoters/
# in a checkout, where the gates live at ../gates.
_promoter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_promoter_dir}/lib.sh" ]]; then
	GATES_DIR="${_promoter_dir}"
else
	GATES_DIR="${_promoter_dir}/../gates"
fi

# shellcheck source=../gates/lib.sh disable=SC1091
source "${GATES_DIR}/lib.sh"

usage() {
	printf '%s\n' "usage: promote-ghcr.sh [--dry-run]" >&2
}

DRY_RUN=0
case "${1:-}" in
-h | --help)
	usage
	exit 0
	;;
--dry-run)
	DRY_RUN=1
	;;
"")
	;;
*)
	usage
	exit 1
	;;
esac

ci_setup_reports
ci_require_cmd crane
ci_require_cmd cosign
ci_require_cmd trivy

# SOURCE_REPO is "<owner>/<repo>" on GitHub (credential; never printed).
# Strip whitespace: a credential read from a one-line file keeps its trailing newline,
# which the anchored name checks below would (correctly) refuse.
SOURCE_REPO="$(printf '%s' "${SOURCE_REPO:-}" | tr -d ' \t\r\n')"
[[ -n "${SOURCE_REPO}" ]] || ci_die "SOURCE_REPO is unset (Jenkins credential <app>-source-repo)"
OWNER="${SOURCE_REPO%%/*}"
REPO="${SOURCE_REPO##*/}"
# GitHub usernames are [A-Za-z0-9-] and repo names [A-Za-z0-9._-]; anything else is a
# typo in the credential (and OWNER is interpolated into a regexp below, so it must
# not be able to inject metacharacters).
[[ "${OWNER}" =~ ^[A-Za-z0-9-]+$ ]] || ci_die "SOURCE_REPO owner is not a GitHub username"
[[ "${REPO}" =~ ^[A-Za-z0-9._-]+$ ]] || ci_die "SOURCE_REPO repo is not a GitHub repository name"

GHCR_TAG="${GHCR_TAG:-main}"
# The package name is what the release workflow pushes (ghcr.io/<owner>/<GHCR_IMAGE>),
# which is NOT the repo name (personal-site's lab-release.yml pushes "personal-site").
# Set by the Jenkinsfile; it carries no domain, so it may live in git. GHCR image paths
# are lowercase.
[[ -n "${GHCR_IMAGE:-}" ]] || ci_die "GHCR_IMAGE is unset (the GHCR package name the release workflow pushes)"
[[ "${GHCR_IMAGE}" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] || ci_die "GHCR_IMAGE is not a valid lowercase image name"
GHCR_REF="ghcr.io/$(printf '%s' "${OWNER}" | tr '[:upper:]' '[:lower:]')/${GHCR_IMAGE}"

# The release workflow file whose keyless identity this run verifies
# (.github/workflows/<GHCR_WORKFLOW> on refs/heads/main). Both apps use lab-release.yml.
# Same strictness as GHCR_IMAGE; the value is interpolated into a regexp below, so its
# only regexp metacharacter ('.') is escaped first.
GHCR_WORKFLOW="${GHCR_WORKFLOW:-lab-release.yml}"
[[ "${GHCR_WORKFLOW}" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] || ci_die "GHCR_WORKFLOW is not a valid workflow file name"
GHCR_WORKFLOW_RE="${GHCR_WORKFLOW//./\\.}"

# Keyless identity: Fulcio issuer + the workflow in the SAN + the repository claim in
# the OIDC token. The regexp keeps <owner> pinned but tolerates a renamed repo; the
# repository flag then rejects any other repo outright.
ID_ISSUER="https://token.actions.githubusercontent.com"
ID_REGEXP="^https://github\\.com/${OWNER}/[^/]+/\\.github/workflows/${GHCR_WORKFLOW_RE}@refs/heads/main$"
VERIFY_FLAGS=(
	--certificate-oidc-issuer "${ID_ISSUER}"
	--certificate-identity-regexp "${ID_REGEXP}"
	--certificate-github-workflow-repository "${SOURCE_REPO}"
)

# cosign reads COSIGN_KEY from the environment as --key, and --key plus a keyless identity
# is an error. The Jenkinsfile exports the LAB key for step 6, so the keyless checks run
# with it removed (build #3 failed on exactly this, 2026-11-09).
keyless() { env -u COSIGN_KEY -u COSIGN_PASSWORD cosign "$@"; }

# 1. Resolve the tag to a digest. The digest is the only thing this script trusts.
DIGEST="$(crane digest "${GHCR_REF}:${GHCR_TAG}")" || ci_die "cannot resolve ${GHCR_TAG} (is the GHCR package public?)"
[[ "${DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || ci_die "crane returned something that is not a digest"
SOURCE_REF="${GHCR_REF}@${DIGEST}"
ci_log "promote: ${GHCR_TAG} is ${DIGEST}"

# 2. Keyless signature must come from the release workflow on main.
keyless verify "${VERIFY_FLAGS[@]}" "${SOURCE_REF}" \
	>"${REPORT_DIR}/ghcr-signature.json" || ci_die "keyless signature verification failed"
ci_log "promote: keyless signature verified (issuer ${ID_ISSUER}, workflow ${GHCR_WORKFLOW}@main)"

# 3. SPDX attestation, same identity. cosign prints the verified attestations to stdout.
keyless verify-attestation --type spdxjson "${VERIFY_FLAGS[@]}" "${SOURCE_REF}" \
	>"${REPORT_DIR}/ghcr-attestation.json" || ci_die "SPDX attestation verification failed"
[[ -s "${REPORT_DIR}/ghcr-attestation.json" ]] || ci_die "no SPDX attestation for ${DIGEST}"
ci_log "promote: SPDX attestation verified"

# 4. Trivy re-scan of the digest: same two-pass rule as gates/image.sh (report first,
#    then HIGH/CRITICAL with a fix available fails the build).
cache="$(ci_trivy_cache_dir)"
mkdir -p "${cache}"
ci_trivy image --cache-dir "${cache}" --scanners vuln \
	--format json --output "${REPORT_DIR}/image.json" --exit-code 0 \
	"${SOURCE_REF}"
ci_trivy image --cache-dir "${cache}" --scanners vuln \
	--severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
	"${SOURCE_REF}"
ci_log "promote: trivy re-scan clean (HIGH/CRITICAL with fixes: none)"

if [[ "${DRY_RUN}" -eq 1 ]]; then
	ci_log "promote: --dry-run: verification passed for ${DIGEST}; nothing copied or signed"
	exit 0
fi

# --- Past here the promoter writes: Nexus, cosign, and a PR in apps-deploy. ---

ci_require_cmd syft
ci_require_cmd curl
ci_require_cmd git
ci_require_cmd python3
if [[ -z "${KUSTOMIZE_CMD:-}" ]]; then
	ci_require_cmd docker
fi

# Per-app destinations. Defaults keep personal-site-promoter unchanged; govgraph-promoter
# sets GHCR_IMAGE, DEST_IMAGE, OVERLAY_DIR, IMAGE_NAME, PROMOTE_APP, PROMOTE_BRANCH_PREFIX.
DEST_IMAGE="${DEST_IMAGE:-registry.home.arpa/personal-site/site}"
DEST_REF="${DEST_IMAGE}@${DIGEST}"
PROMOTE_APP="${PROMOTE_APP:-personal-site}"
PROMOTE_BRANCH_PREFIX="${PROMOTE_BRANCH_PREFIX:-site}"
[[ "${PROMOTE_APP}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || ci_die "PROMOTE_APP is not a valid app id"
[[ "${PROMOTE_BRANCH_PREFIX}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || ci_die "PROMOTE_BRANCH_PREFIX is not a valid branch prefix"

[[ -n "${GITEA_PROMOTE_USER:-}" ]] || ci_die "GITEA_PROMOTE_USER is unset"
[[ -n "${GITEA_PROMOTE_TOKEN:-}" ]] || ci_die "GITEA_PROMOTE_TOKEN is unset"
[[ -n "${COSIGN_KEY:-}" ]] || ci_die "COSIGN_KEY is unset"
[[ -f "${COSIGN_KEY}" ]] || ci_die "COSIGN_KEY is not a file: ${COSIGN_KEY}"
[[ -n "${COSIGN_PASSWORD:-}" ]] || ci_die "COSIGN_PASSWORD is unset"

# 7. Find out whether this digest is already promoted (staging overlay on main, or an
#    open promote branch), then copy + sign (5, 6) and PR the pin. Same Gitea pattern as gates/promote.sh:
#    owner derived from GIT_URL (never in git), token via GIT_ASKPASS and curl -K stdin,
#    kustomize edit via the pinned container, 409/422 tolerated.
PROMOTE_TOKEN="$(printf '%s' "${GITEA_PROMOTE_TOKEN-}" | tr -d '\r\n')"
[[ -n "${PROMOTE_TOKEN}" ]] || ci_die "promote token is empty"
export PROMOTE_TOKEN
export GITEA_PROMOTE_USER

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

DEPLOY_REPO="${DEPLOY_REPO:-apps-deploy}"
OVERLAY_DIR="${OVERLAY_DIR:-apps/personal-site/overlays/staging}"
IMAGE_NAME="${IMAGE_NAME:-${DEST_IMAGE}}"
KUSTOMIZE_IMAGE="${KUSTOMIZE_IMAGE:-registry.k8s.io/kustomize/kustomize:v5.8.3@sha256:429eda4a1c76a7de458d0c4ca3ded9b5d764899ff6bdaeccc1d98b1b6ee873e4}"
PROMOTE_REMOTE="${PROMOTE_REMOTE:-${GITEA_URL}/${GITEA_OWNER}/${DEPLOY_REPO}.git}"
api="${GITEA_URL}/api/v1/repos/${GITEA_OWNER}/${DEPLOY_REPO}/pulls"

gitea_api() {
	printf 'header = "Authorization: token %s"\n' "${PROMOTE_TOKEN}" | curl -q -K - "$@"
}

askpass="$(mktemp "${TMPDIR:-/tmp}/promote-askpass.XXXXXX")"
tmpfiles=("${askpass}")
cleanup() { rm -f "${tmpfiles[@]}"; }
trap cleanup EXIT
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

overlay_digest() {
	# Current digest the overlay pins for IMAGE_NAME ("" when it pins nothing).
	python3 - "${IMAGE_NAME}" "${1:-${OVERLAY_DIR}/kustomization.yaml}" <<'PY'
import sys

want, path = sys.argv[1], sys.argv[2]
# Read each entry of the top-level images: list as a whole. kustomize edit set image
# rewrites entries with keys sorted ("- digest:" before "name:"), so the key order of
# an entry must not matter (2026-11-09: an order-dependent parser made every run
# re-sign an already promoted digest).
items, cur, in_images = [], None, False
for raw in open(path, encoding="utf-8"):
    line = raw.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if line.startswith("images:"):
        in_images = True
        continue
    if in_images and not line[0].isspace() and not line.startswith("-"):
        in_images = False
    if not in_images:
        continue
    body = line.strip()
    if body.startswith("- "):
        cur = {}
        items.append(cur)
        body = body[2:].strip()
    if cur is not None and ":" in body:
        k, v = body.split(":", 1)
        cur[k.strip()] = v.strip().strip("\"'")
print(next((i.get("digest", "") for i in items if i.get("name") == want), ""))
PY
}

run_kustomize() {
	if [[ -n "${KUSTOMIZE_CMD:-}" ]]; then
		(cd "${OVERLAY_DIR}" && "${KUSTOMIZE_CMD}" edit set image "$@")
	else
		docker run --rm \
			--user "$(id -u):$(id -g)" \
			-v "$(pwd):/work" \
			-w "/work/${OVERLAY_DIR}" \
			"${KUSTOMIZE_IMAGE}" \
			edit set image "$@"
	fi
}

short="${DIGEST#sha256:}"
short="${short:0:12}"
BRANCH="promote/${PROMOTE_BRANCH_PREFIX}-${short}"

rm -rf "${DEPLOY_REPO}"
git_auth clone "${PROMOTE_REMOTE}" "${DEPLOY_REPO}" || ci_die "cannot clone ${DEPLOY_REPO}"
cd "${DEPLOY_REPO}" || ci_die "clone did not create ${DEPLOY_REPO}"

# Promoted already = main's staging overlay pins this digest: stop before writing anything.
main_overlay="$(mktemp "${TMPDIR:-/tmp}/promote-main-overlay.XXXXXX")"
tmpfiles+=("${main_overlay}")
git show "origin/main:${OVERLAY_DIR}/kustomization.yaml" >"${main_overlay}" || ci_die "no ${OVERLAY_DIR} on main"
if [[ "$(overlay_digest "${main_overlay}")" == "${DIGEST}" ]]; then
	ci_log "promote: staging overlay on main already pins ${DIGEST}; nothing to do"
	exit 0
fi

if ! git_auth fetch origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}"; then
	ci_log "promote: no existing ${BRANCH} on remote"
fi
if git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; then
	git checkout -B "${BRANCH}" "origin/${BRANCH}"
else
	git checkout -B "${BRANCH}" origin/main
fi

if [[ "$(overlay_digest)" == "${DIGEST}" ]]; then
	# An earlier run copied, signed and pushed this branch; it may have died before the
	# PR call. Skip the writes and fall through to "make sure the PR exists".
	ci_log "promote: ${BRANCH} already pins ${DIGEST}; checking its PR"
else
	# 5. Only reached for a digest not yet promoted, so a finished promotion is not
	#    re-copied and re-signed every 15 minutes (each run would append another
	#    signature + attestation in Nexus). Copy digest-preserving. Auth for
	#    registry.home.arpa comes from the docker login the Jenkinsfile did (crane
	#    reads ~/.docker/config.json); GHCR stays anonymous.
	ci_log "promote: crane copy -> ${DEST_REF}"
	crane copy "${SOURCE_REF}" "${DEST_IMAGE}" || ci_die "crane copy failed"
	COPIED="$(crane digest "${DEST_REF}")" || ci_die "cannot read back ${DEST_REF}"
	[[ "${COPIED}" == "${DIGEST}" ]] || ci_die "digest changed in transit: ${COPIED}"

	# 6. SBOM of the copy, then lab-key signature + SPDX attestation (gates/sign.sh).
	syft scan "${DEST_REF}" -o "spdx-json=${REPORT_DIR}/sbom.spdx.json" || ci_die "syft failed"
	"${GATES_DIR}/sign.sh" "${DEST_REF}" || ci_die "sign.sh failed"
	ci_log "promote: lab key signature + SPDX attestation on ${DEST_REF}"

	run_kustomize "${IMAGE_NAME}=${DEST_REF}"
	git add "${OVERLAY_DIR}/kustomization.yaml"
	git diff --cached --quiet && ci_die "kustomize wrote no change, but the overlay did not pin ${DIGEST}"
	git -c user.name=ci-promote -c user.email=ci-promote@home.arpa \
		commit -m "promote ${PROMOTE_APP} ${short}" || ci_die "git commit failed"
	git_auth push -u origin "${BRANCH}" || ci_die "git push failed"
fi

pulls_body="$(mktemp "${TMPDIR:-/tmp}/promote-pulls.XXXXXX")"
tmpfiles+=("${pulls_body}")
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
	ci_log "promote: PR #${existing} already open for ${BRANCH}; branch updated"
	exit 0
fi

pr_json="$(mktemp "${TMPDIR:-/tmp}/promote-pr.XXXXXX")"
tmpfiles+=("${pr_json}")
# $BRANCH is built once above and passed in; the payload must never rebuild it.
python3 - "${DIGEST}" "${DEST_REF}" "${pr_json}" "${PROMOTE_APP}" "${BRANCH}" "${GHCR_WORKFLOW}" <<'PY'
import json, os, sys

digest, dest_ref, path, app, branch, workflow = sys.argv[1:7]
body = (
    f"image: `{dest_ref}`\n"
    f"Jenkins: {os.environ.get('BUILD_URL', '')}\n"
    f"Verified keyless (issuer token.actions.githubusercontent.com, workflow"
    f" {workflow}@main), Trivy re-scan clean, copied digest-preserving,"
    " re-signed + SPDX attested with the lab key.\n"
)
payload = {
    "title": f"promote {app} {digest[7:19]}",
    "head": branch,
    "base": "main",
    "body": body,
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh)
PY

create_body="$(mktemp "${TMPDIR:-/tmp}/promote-create.XXXXXX")"
tmpfiles+=("${create_body}")
# JSON is a file, not stdin: stdin is already the curl -K config.
create_code="$(gitea_api -sS -o "${create_body}" -w '%{http_code}' \
	-H "Content-Type: application/json" \
	--data-binary "@${pr_json}" \
	"${api}")"
case "${create_code}" in
201)
	ci_log "promote: opened staging PR for ${DIGEST}"
	;;
409 | 422)
	if grep -qi 'already exists' "${create_body}"; then
		ci_log "promote: PR already exists (HTTP ${create_code}); branch updated"
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

ci_log "promote: pass"
