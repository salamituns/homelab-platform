#!/usr/bin/env bash
# Cosign sign + SBOM attestation. Private lab: no public Rekor (--tlog-upload=false).
# Pipeline must docker login first; cosign reuses ~/.docker/config.json.

# shellcheck source=lib.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
	printf '%s\n' "usage: sign.sh <registry/repo@sha256:digest>" >&2
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

# Tag-only refs can move; the digest is what we actually built.
[[ "${image_ref}" == *@sha256:* ]] || ci_die "ref must include a digest (@sha256:...), got: ${image_ref}"

[[ -n "${COSIGN_KEY:-}" ]] || ci_die "COSIGN_KEY must be set to the encrypted private key file"
[[ -f "${COSIGN_KEY}" ]] || ci_die "COSIGN_KEY is not a file: ${COSIGN_KEY}"
[[ -n "${COSIGN_PASSWORD:-}" ]] || ci_die "COSIGN_PASSWORD must be set (cosign reads it from the environment)"
[[ -s "${REPORT_DIR}/sbom.spdx.json" ]] || ci_die "missing ${REPORT_DIR}/sbom.spdx.json (run sbom.sh first)"

ci_require_cmd cosign
ci_log "sign: cosign sign+attest ${image_ref}"

# -y skips the "are you sure" prompt in CI. COSIGN_PASSWORD unlocks --key.
# attest still accepts --tlog-upload=false in cosign 3.1.4 (deprecated warning).
cosign sign --yes --key "${COSIGN_KEY}" --tlog-upload=false "${image_ref}"
cosign attest --yes --key "${COSIGN_KEY}" --tlog-upload=false \
	--type spdxjson --predicate "${REPORT_DIR}/sbom.spdx.json" \
	"${image_ref}"

ci_log "sign: pass"
