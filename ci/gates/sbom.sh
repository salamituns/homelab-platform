#!/usr/bin/env bash
# Syft SBOM in SPDX JSON. The file name is fixed so sign.sh can attest it.

# shellcheck source=lib.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
	printf '%s\n' "usage: sbom.sh <image-ref>" >&2
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
ci_require_cmd syft
ci_log "sbom: syft ${image_ref}"

syft scan "${image_ref}" -o "spdx-json=${REPORT_DIR}/sbom.spdx.json"
[[ -s "${REPORT_DIR}/sbom.spdx.json" ]] || ci_die "syft wrote an empty SBOM"

ci_log "sbom: wrote ${REPORT_DIR}/sbom.spdx.json"
