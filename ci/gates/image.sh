#!/usr/bin/env bash
# Trivy image scan (OS packages + language deps). Same HIGH/CRITICAL+fix rule as deps.sh.

# shellcheck source=lib.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
	printf '%s\n' "usage: image.sh <image-ref>" >&2
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi
[[ $# -eq 1 ]] || {
	usage
	exit 1
}

image_ref="$1"
ci_setup_reports
ci_check_trivyignore "${PWD}"
ci_require_cmd trivy

cache="$(ci_trivy_cache_dir)"
mkdir -p "${cache}"
ci_log "image: trivy image ${image_ref} (cache ${cache})"

CI_TRIVY_IGNOREFILE=""
if [[ -f "${PWD}/.trivyignore.yaml" ]]; then
	CI_TRIVY_IGNOREFILE="${PWD}/.trivyignore.yaml"
elif [[ -f "${PWD}/.trivyignore.yml" ]]; then
	CI_TRIVY_IGNOREFILE="${PWD}/.trivyignore.yml"
fi
export CI_TRIVY_IGNOREFILE

ci_trivy image --cache-dir "${cache}" --scanners vuln \
	--format json --output "${REPORT_DIR}/image.json" --exit-code 0 \
	"${image_ref}"
ci_trivy image --cache-dir "${cache}" --scanners vuln \
	--severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
	"${image_ref}"

ci_log "image: pass"
