#!/usr/bin/env bash
# Local/agent proof that secrets.sh and deps.sh fail dirty fixtures and pass clean ones.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="${ROOT}/tests/fixtures"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ci-gates-tests.XXXXXX")"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

git_init() {
	local dir="$1"
	git -C "${dir}" init -q
	git -C "${dir}" config user.email "admin@home.arpa"
	git -C "${dir}" config user.name "ci-gates-test"
	git -C "${dir}" add -A
	git -C "${dir}" commit -q -m "fixture"
}

expect_fail() {
	local name="$1"
	shift
	local rc=0
	"$@" >/dev/null 2>"${WORKDIR}/${name}.err" || rc=$?
	if [[ "${rc}" -eq 0 ]]; then
		printf 'FAIL: %s was expected to fail\n' "${name}" >&2
		cat "${WORKDIR}/${name}.err" >&2
		exit 1
	fi
	printf 'ok  %s failed as expected (exit %s)\n' "${name}" "${rc}"
}

expect_pass() {
	local name="$1"
	shift
	if ! "$@" >/dev/null 2>"${WORKDIR}/${name}.err"; then
		printf 'FAIL: %s was expected to pass\n' "${name}" >&2
		cat "${WORKDIR}/${name}.err" >&2
		exit 1
	fi
	printf 'ok  %s passed\n' "${name}"
}

cp -R "${FIX}/dirty" "${WORKDIR}/dirty"
cp -R "${FIX}/clean" "${WORKDIR}/clean"
git_init "${WORKDIR}/dirty"
git_init "${WORKDIR}/clean"

export REPORT_DIR="${WORKDIR}/reports"

expect_fail secrets-dirty "${ROOT}/secrets.sh" "${WORKDIR}/dirty"
expect_pass secrets-clean "${ROOT}/secrets.sh" "${WORKDIR}/clean"

expect_fail deps-dirty "${ROOT}/deps.sh" "${WORKDIR}/dirty"
expect_pass deps-clean "${ROOT}/deps.sh" "${WORKDIR}/clean"

expect_fail sign-no-args "${ROOT}/sign.sh"
expect_fail sign-no-digest "${ROOT}/sign.sh" "registry.home.arpa/belleshop/backend:abc123"
COSIGN_KEY="${WORKDIR}/missing.key" COSIGN_PASSWORD="x" REPORT_DIR="${WORKDIR}/reports" \
	expect_fail sign-missing-key "${ROOT}/sign.sh" \
	"registry.home.arpa/belleshop/backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

printf 'all gate tests passed\n'
