#!/usr/bin/env bash
# Parse /var/log/lynis-report.dat into a node-exporter textfile.
# Separate unit from lynis.service so Falco still sees the packaged ExecStart.
set -euo pipefail

REPORT="${LYNIS_REPORT:-/var/log/lynis-report.dat}"
OUTDIR="${LYNIS_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
OUT="${LYNIS_TEXTFILE_PATH:-${OUTDIR}/lynis.prom}"

if [[ ! -r "${REPORT}" ]]; then
  echo "lynis-textfile: cannot read ${REPORT}" >&2
  exit 1
fi

mkdir -p -- "${OUTDIR}"

index="$(awk -F= '/^hardening_index=/{print $2; exit}' "${REPORT}")"
version="$(awk -F= '/^lynis_version=/{print $2; exit}' "${REPORT}")"
ended="$(awk -F= '/^report_datetime_end=/{print substr($0, index($0,"=")+1); exit}' "${REPORT}")"
started="$(awk -F= '/^report_datetime_start=/{print substr($0, index($0,"=")+1); exit}' "${REPORT}")"
warnings="$(grep -c '^warning\[\]=' "${REPORT}" || true)"
suggestions="$(grep -c '^suggestion\[\]=' "${REPORT}" || true)"

if [[ -z "${index}" || -z "${version}" ]]; then
  echo "lynis-textfile: missing hardening_index or lynis_version in ${REPORT}" >&2
  exit 1
fi

when="${ended:-${started}}"
if [[ -z "${when}" ]]; then
  ts="$(stat -c %Y "${REPORT}")"
else
  # Report stamps are naive local time (live: "2026-11-07 00:26:23").
  ts="$(TZ=America/Chicago date -d "${when}" +%s)"
fi

# Label values must be prometheus-safe; version is digits and dots only.
tmp="$(mktemp "${OUTDIR}/lynis.prom.XXXXXX")"
trap 'rm -f -- "${tmp}"' EXIT
umask 022
cat > "${tmp}" <<EOF
# HELP lynis_hardening_index Lynis hardening index from the last cron report (0-100).
# TYPE lynis_hardening_index gauge
lynis_hardening_index ${index}
# HELP lynis_warnings Count of warning[] lines in the last Lynis report.
# TYPE lynis_warnings gauge
lynis_warnings ${warnings}
# HELP lynis_suggestions Count of suggestion[] lines in the last Lynis report.
# TYPE lynis_suggestions gauge
lynis_suggestions ${suggestions}
# HELP lynis_report_timestamp_seconds Unix time of report_datetime_end (America/Chicago).
# TYPE lynis_report_timestamp_seconds gauge
lynis_report_timestamp_seconds ${ts}
# HELP lynis_info Lynis package version from the last report.
# TYPE lynis_info gauge
lynis_info{version="${version}"} 1
EOF
chmod 0644 -- "${tmp}"
mv -f -- "${tmp}" "${OUT}"
trap - EXIT
