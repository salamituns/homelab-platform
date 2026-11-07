#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote commands are built on the Mac on purpose (values are ours, not user input)
# Build and push the Argo Rollouts Gateway API plugin image to Nexus (PR #89).
# Run from the Mac. Work happens on ci-agent in a root-only temp dir with its own
# DOCKER_CONFIG; registry passwords go nexus -> ci-agent over ssh stdin
# (--password-stdin), never argv, never this terminal, deleted with the temp dir.
#
#   scripts/rollouts-plugin-image.sh --dry-run   # download + sha256 + plan, no login, no push
#   scripts/rollouts-plugin-image.sh             # build as ci-pull, push as ci-push
set -euo pipefail

CI_AGENT="tunsadmin@192.168.1.93"
NEXUS="tunsadmin@192.168.1.87"
REGISTRY="registry.home.arpa"
IMAGE="${REGISTRY}/belleshop/rollouts-gatewayapi-plugin:v0.17.0"
URL="https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/v0.17.0/gatewayapi-plugin-linux-amd64"
SHA="1904ca787d33107c140521899d61fff030ee75d99908bd175fca5a4647759061"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DOCKERFILE="${HERE}/k8s/platform/argo-rollouts/plugin-image/Dockerfile"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

[[ -r "${DOCKERFILE}" ]] || { echo "missing ${DOCKERFILE}" >&2; exit 1; }

# -n: these ssh calls must never read this script's stdin.
work="$(ssh -n "${CI_AGENT}" 'sudo -n mktemp -d /tmp/rollouts-plugin.XXXXXX')"
cleanup() {
  ssh -n "${CI_AGENT}" "sudo -n env DOCKER_CONFIG='${work}/docker' docker logout '${REGISTRY}' >/dev/null 2>&1 || true; sudo -n rm -rf -- '${work}'"
}
trap cleanup EXIT
echo "ci-agent workdir: ${work} (0700, removed on exit)"

# Build context: Dockerfile from git + the release binary, checked before anything else.
ssh "${CI_AGENT}" "sudo -n tee '${work}/Dockerfile' >/dev/null" < "${DOCKERFILE}"
# The workdir is root 0700, so the whole block runs as root (a plain cd is denied).
ssh -n "${CI_AGENT}" "sudo -n bash -c \"set -euo pipefail; cd '${work}'
  curl -qfsSL -o gatewayapi-plugin-linux-amd64 '${URL}'
  echo '${SHA}  gatewayapi-plugin-linux-amd64' | sha256sum -c
  install -d -m 0700 '${work}/docker'\""

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "DRY-RUN: would log in as ci-pull, build ${IMAGE}, log in as ci-push, push (allow_once), print digest"
  exit 0
fi

login() { # $1 = nexus service user
  ssh -n "${NEXUS}" "sudo -n cat /etc/nexus/secrets/$1" \
    | ssh "${CI_AGENT}" "sudo -n env DOCKER_CONFIG='${work}/docker' docker login -u '$1' --password-stdin '${REGISTRY}' >/dev/null"
  echo "logged in as $1 (temp DOCKER_CONFIG)"
}

login ci-pull
# allow_once: if the tag already exists, never try to overwrite it.
if ssh -n "${CI_AGENT}" "sudo -n env DOCKER_CONFIG='${work}/docker' docker manifest inspect '${IMAGE}' >/dev/null 2>&1"; then
  echo "${IMAGE} already exists in Nexus; not rebuilding (allow_once)."
else
  ssh -n "${CI_AGENT}" "sudo -n env DOCKER_CONFIG='${work}/docker' docker build --pull -q -t '${IMAGE}' '${work}'"
  login ci-push
  ssh -n "${CI_AGENT}" "sudo -n env DOCKER_CONFIG='${work}/docker' docker push -q '${IMAGE}'"
fi

digest="$(ssh -n "${CI_AGENT}" "sudo -n env DOCKER_CONFIG='${work}/docker' docker buildx imagetools inspect '${IMAGE}' --format '{{json .Manifest.Digest}}' 2>/dev/null || true")"
echo "pushed: ${IMAGE}"
echo "registry digest: ${digest//\"/}"
echo "Next: merge PR #89 (the nexus-pull Secret must already be in argo-rollouts)."
