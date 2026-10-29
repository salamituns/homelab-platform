#!/usr/bin/env bash
# Trivy filesystem scan: dependency manifests + Dockerfile/k8s misconfig.
# Fails on HIGH/CRITICAL with a fix available (vulns) and HIGH/CRITICAL misconfig.

# shellcheck source=lib.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
	printf '%s\n' "usage: deps.sh <dir>" >&2
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi
[[ $# -eq 1 ]] || {
	usage
	exit 1
}

target="$(cd "$1" && pwd)" || ci_die "not a directory: $1"
ci_setup_reports
ci_check_trivyignore "${target}"
ci_require_cmd trivy

cache="$(ci_trivy_cache_dir)"
mkdir -p "${cache}"
ci_log "deps: trivy fs ${target} (cache ${cache})"

CI_TRIVY_IGNOREFILE=""
if [[ -f "${target}/.trivyignore.yaml" ]]; then
	CI_TRIVY_IGNOREFILE="${target}/.trivyignore.yaml"
elif [[ -f "${target}/.trivyignore.yml" ]]; then
	CI_TRIVY_IGNOREFILE="${target}/.trivyignore.yml"
fi
export CI_TRIVY_IGNOREFILE

# Record run: every severity, exit 0, JSON for the pipeline archive.
# Gate run: Trivy applies --ignore-unfixed itself (FixedVersion empty ≠ a simple
# jq filter). Secrets are out of scope here; secrets.sh owns that.
ci_trivy fs --cache-dir "${cache}" --scanners vuln,misconfig \
	--format json --output "${REPORT_DIR}/deps.json" --exit-code 0 \
	"${target}"
ci_trivy fs --cache-dir "${cache}" --scanners vuln,misconfig \
	--severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
	"${target}"

ci_log "deps: pass"
