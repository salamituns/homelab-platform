#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote commands are built on the Mac on purpose (values are ours, not user input)
# Build and push the Argo Rollouts Gateway API plugin image to Nexus (PR #89).
# Run from the Mac. Work happens on ci-agent in a root-only temp dir with its own
# DOCKER_CONFIG; registry passwords go nexus -> ci-agent over ssh stdin
# (--password-stdin), never argv, never this terminal, deleted with the temp dir.
#
#   scripts/rollouts-plugin-image.sh --dry-run   # download + sha256 + plan, no login, no push
#   scripts/rollouts-plugin-image.sh --build-only # + build (no credentials), then clean up
#   scripts/rollouts-plugin-image.sh --build-only # + build without credentials, re-verify, clean up
#   scripts/rollouts-plugin-image.sh             # build, push as ci-push
set -euo pipefail

CI_AGENT="tunsadmin@192.168.1.93"
NEXUS="tunsadmin@192.168.1.87"
REGISTRY="registry.home.arpa"
IMAGE="${REGISTRY}/belleshop/rollouts-gatewayapi-plugin:v0.17.0"
URL="https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/v0.17.0/gatewayapi-plugin-linux-amd64"
SHA="1904ca787d33107c140521899d61fff030ee75d99908bd175fca5a4647759061"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DOCKERFILE="${HERE}/k8s/platform/argo-rollouts/plugin-image/Dockerfile"

MODE=push
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --build-only) MODE=build ;;
  "") ;;
  *) echo "usage: $0 [--dry-run|--build-only]" >&2; exit 2 ;;
esac

[[ -r "${DOCKERFILE}" ]] || { echo "missing ${DOCKERFILE}" >&2; exit 1; }

# -n: these ssh calls must never read this script's stdin.
work="$(ssh -n "${CI_AGENT}" 'sudo -n mktemp -d /tmp/rollouts-plugin.XXXXXX')"
cleanup() {
  ssh -n "${CI_AGENT}" "sudo -n env DOCKER_CONFIG='${work}/docker' docker logout '${REGISTRY}' >/dev/null 2>&1 || true; sudo -n docker image rm -f '${IMAGE}' >/dev/null 2>&1 || true; sudo -n rm -rf -- '${work}'"
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

if [[ "${MODE}" == "dry" ]]; then
  echo "DRY-RUN: would build ${IMAGE} (busybox from Docker Hub by digest), log in as ci-push, push (allow_once), print digest"
  exit 0
fi

build() {
  ssh -n "${CI_AGENT}" "sudo -n env DOCKER_CONFIG='${work}/docker' docker build --pull -q -t '${IMAGE}' '${work}'"
  # Same as the Kubernetes initContainer: uid 65534, read-only root, emptyDir target.
  ssh -n "${CI_AGENT}" "sudo -n docker run --rm --user 65534 --read-only --tmpfs /home/argo-rollouts/plugin-bin:mode=1777 --entrypoint /bin/sh '${IMAGE}' -c 'echo ${SHA}  /plugin/gatewayapi-plugin-linux-amd64 | sha256sum -c && cp /plugin/gatewayapi-plugin-linux-amd64 /home/argo-rollouts/plugin-bin/ && ls -l /home/argo-rollouts/plugin-bin/ && test -x /home/argo-rollouts/plugin-bin/gatewayapi-plugin-linux-amd64 && echo copied-and-executable'"
}

if [[ "${MODE}" == "build" ]]; then
  build
  echo "BUILD-ONLY: image built and its binary re-verified; nothing pushed (image removed on exit)"
  exit 0
fi

login() { # $1 = nexus service user
  ssh -n "${NEXUS}" "sudo -n cat /etc/nexus/secrets/$1" \
    | ssh "${CI_AGENT}" "sudo -n env DOCKER_CONFIG='${work}/docker' docker login -u '$1' --password-stdin '${REGISTRY}' >/dev/null"
  echo "logged in as $1 (temp DOCKER_CONFIG)"
}

# ci-push may read and write belleshop only; the base image needs no registry login.
login ci-push
# allow_once: if the tag already exists, never try to overwrite it.
if ssh -n "${CI_AGENT}" "sudo -n env DOCKER_CONFIG='${work}/docker' docker manifest inspect '${IMAGE}' >/dev/null 2>&1"; then
  echo "${IMAGE} already exists in Nexus; not rebuilding (allow_once)."
else
  build
  ssh -n "${CI_AGENT}" "sudo -n env DOCKER_CONFIG='${work}/docker' docker push -q '${IMAGE}'"
fi

digest="$(ssh -n "${CI_AGENT}" "sudo -n env DOCKER_CONFIG='${work}/docker' docker buildx imagetools inspect '${IMAGE}' --format '{{json .Manifest.Digest}}' 2>/dev/null || true")"
echo "pushed: ${IMAGE}"
echo "registry digest: ${digest//\"/}"
echo "Next: merge PR #89 (the nexus-pull Secret must already be in argo-rollouts)."
