#!/usr/bin/env bash
# Shared helpers for /opt/ci-gates. Sourced by every gate script.
# WHY: one place for logging, REPORT_DIR, and the .trivyignore.yaml policy so a
# pipeline cannot weaken those rules by copying a half-finished snippet.

set -euo pipefail

ci_log() {
	printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

ci_die() {
	ci_log "ERROR: $*"
	exit 1
}

ci_setup_reports() {
	REPORT_DIR="${REPORT_DIR:-reports}"
	mkdir -p "${REPORT_DIR}"
	REPORT_DIR="$(cd "${REPORT_DIR}" && pwd)"
	export REPORT_DIR
}

ci_require_cmd() {
	command -v "$1" >/dev/null 2>&1 || ci_die "required command not found: $1"
}

# Fail closed on exception files: every ignore needs a reason and a short expiry
# (ADR 0011). Trivy itself does not enforce the 90-day cap.
ci_check_trivyignore() {
	local root="${1:-.}"
	local ignore=""
	if [[ -f "${root}/.trivyignore.yaml" ]]; then
		ignore="${root}/.trivyignore.yaml"
	elif [[ -f "${root}/.trivyignore.yml" ]]; then
		ignore="${root}/.trivyignore.yml"
	else
		return 0
	fi

	ci_require_cmd python3
	python3 - "${ignore}" <<'PY'
import re
import sys
from datetime import date, timedelta
from pathlib import Path

path = Path(sys.argv[1])
lines = []
for raw in path.read_text(encoding="utf-8").splitlines():
    stripped = raw.strip()
    if not stripped or stripped.startswith("#"):
        continue
    lines.append(raw)

items = []
item = None


def flush():
    global item
    if item is not None:
        items.append(item)
        item = None


for line in lines:
    top = re.match(r"^(\w+)\s*:\s*$", line)
    if top:
        flush()
        continue
    start = re.match(r"^(\s+)-\s+(.*)$", line)
    if start:
        flush()
        rest = start.group(2).strip()
        item = {}
        if rest.startswith("id:"):
            item["id"] = rest.split(":", 1)[1].strip().strip("\"'")
        elif ":" not in rest:
            item["id"] = rest.strip().strip("\"'")
        else:
            key, value = rest.split(":", 1)
            item[key.strip()] = value.strip().strip("\"'")
        continue
    field = re.match(r"^\s+(\w+)\s*:\s*(.*)$", line)
    if field and item is not None:
        item[field.group(1)] = field.group(2).strip().strip("\"'")
flush()

errors = []
today = date.today()
limit = today + timedelta(days=90)
for entry in items:
    ident = entry.get("id", "<entry>")
    statement = entry.get("statement", "").strip()
    expiry = entry.get("expired_at", "").strip()
    if not statement:
        errors.append(f"{ident}: missing statement (why this exception exists)")
    if not expiry:
        errors.append(f"{ident}: missing expired_at (must be YYYY-MM-DD, ≤ 90 days)")
        continue
    try:
        exp = date.fromisoformat(expiry[:10])
    except ValueError:
        errors.append(f"{ident}: expired_at {expiry!r} is not YYYY-MM-DD")
        continue
    if exp > limit:
        errors.append(
            f"{ident}: expired_at {exp.isoformat()} is more than 90 days away"
        )

if errors:
    sys.stderr.write("invalid .trivyignore.yaml:\n")
    sys.stderr.write("\n".join(f"  - {e}" for e in errors) + "\n")
    sys.exit(1)
PY
}

ci_trivy_cache_dir() {
	# Agent home on the CI VM is /var/lib/jenkins-agent; locally it is $HOME.
	printf '%s\n' "${TRIVY_CACHE_DIR:-${HOME}/.cache/trivy}"
}

# Bash 3.2 (macOS) treats empty arrays as unbound under `set -u`. Keep the
# ignore file in an env var instead of an array.
ci_trivy() {
	# Pin config and ignore files. Trivy otherwise reads trivy.yaml /
	# .trivyignore from cwd, which on the agent is often an admin home the
	# jenkins-agent user cannot open.
	# Vulnerability DBs and the misconfig checks bundle come from the Nexus
	# ghcr.io proxy (registry.home.arpa/aquasecurity/*). Auth is read by Trivy
	# from TRIVY_USERNAME / TRIVY_PASSWORD (or DOCKER_CONFIG) in the environment,
	# never argv.
	local ignore="/dev/null"
	if [[ -n "${CI_TRIVY_IGNOREFILE:-}" ]]; then
		ignore="${CI_TRIVY_IGNOREFILE}"
	fi
	local db_repo="${TRIVY_DB_REPOSITORY:-registry.home.arpa/aquasecurity/trivy-db:2}"
	local java_db_repo="${TRIVY_JAVA_DB_REPOSITORY:-registry.home.arpa/aquasecurity/trivy-java-db:1}"
	local checks_repo="${TRIVY_CHECKS_BUNDLE_REPOSITORY:-registry.home.arpa/aquasecurity/trivy-checks:2}"
	if [[ -n "${TRIVY_USERNAME:-}" ]]; then
		TRIVY_USERNAME="${TRIVY_USERNAME//$'\r'/}"
		TRIVY_USERNAME="${TRIVY_USERNAME//$'\n'/}"
		export TRIVY_USERNAME
	fi
	if [[ -n "${TRIVY_PASSWORD:-}" ]]; then
		TRIVY_PASSWORD="${TRIVY_PASSWORD//$'\r'/}"
		TRIVY_PASSWORD="${TRIVY_PASSWORD//$'\n'/}"
		export TRIVY_PASSWORD
	fi
	trivy --config /dev/null --ignorefile "${ignore}" \
		--db-repository "${db_repo}" \
		--java-db-repository "${java_db_repo}" \
		--checks-bundle-repository "${checks_repo}" \
		"$@"
}
