#!/usr/bin/env bash
# gitleaks on git history. Any finding fails the build (ADR 0011).
# Allowlist only via the app repo's .gitleaks.toml / .gitleaksignore — never here.

# shellcheck source=lib.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
	printf '%s\n' "usage: secrets.sh <dir>" >&2
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
[[ -d "${target}/.git" ]] || ci_die "${target} is not a git repository (gitleaks git mode)"

ci_setup_reports
ci_require_cmd gitleaks
ci_log "secrets: scanning git history of ${target}"

# JSON is the machine record; SARIF is what code-scanning UIs ingest.
# --redact (gitleaks 8.30) hides the secret in both reports and logs.
# Two runs because -f accepts one format. JSON uses --exit-code 0 so a finding
# still writes the file; SARIF carries the real gate exit code.
gitleaks git --no-banner --redact \
	--report-format json --report-path "${REPORT_DIR}/secrets.json" \
	--exit-code 0 \
	"${target}"
gitleaks git --no-banner --redact \
	--report-format sarif --report-path "${REPORT_DIR}/secrets.sarif" \
	--exit-code 1 \
	"${target}"

ci_log "secrets: pass"
