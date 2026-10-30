#!/usr/bin/env bash
# Cosign sign + SBOM attestation. Private lab: no public Rekor (a signing config with no services).
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

# Private lab: no public transparency log. cosign 3.x rejects --tlog-upload=false and wants a signing config instead;
# `signing-config create` with no services gives one without Rekor/TSA (verified 2026-10-29: verify passes with our
# public key and --insecure-ignore-tlog, and fails with any other key).
# -y skips the "are you sure" prompt in CI. COSIGN_PASSWORD unlocks --key.
signing_config="$(mktemp)"
trap 'rm -f "${signing_config}"' EXIT
cosign signing-config create --out "${signing_config}"
cosign sign --yes --key "${COSIGN_KEY}" --signing-config "${signing_config}" "${image_ref}"
cosign attest --yes --key "${COSIGN_KEY}" --signing-config "${signing_config}" \
	--type spdxjson --predicate "${REPORT_DIR}/sbom.spdx.json" \
	"${image_ref}"

ci_log "sign: pass"
