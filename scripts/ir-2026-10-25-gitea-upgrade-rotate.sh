#!/usr/bin/env bash
# Incident 2026-10-25 (CVE-2026-60004 on Gitea): upgrade Gitea, close registration, rotate server secrets.
# Runs ON UbuntuNew as root. Copied there with the verified binary by the operator:
#   scp scripts/ir-2026-10-25-gitea-upgrade-rotate.sh <verified gitea binary> UbuntuNew:/tmp/
#   ssh UbuntuNew 'sudo bash /tmp/ir-2026-10-25-gitea-upgrade-rotate.sh /tmp/gitea-1.27.3-linux-amd64 <sha256>'
# Secret values are generated here and written to app.ini only; nothing is printed.
set -euo pipefail

NEW_BIN="$1"
WANT_SHA="$2"
INI=/etc/gitea/app.ini
BIN=/usr/local/bin/gitea

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ "$(sha256sum "$NEW_BIN" | awk '{print $1}')" = "$WANT_SHA" ] || { echo "ABORT: binary hash mismatch" >&2; exit 1; }

echo "1. stop gitea"
systemctl stop gitea

echo "2. back up binary and app.ini (root-only; contains the OLD secrets, delete after verification)"
ts=$(date +%F-%H%M)
cp -p "$BIN" "/root/gitea-$("$BIN" --version | awk '{print $3}').bak"
install -m 600 -o root -g root "$INI" "/root/app.ini.bak-$ts"

echo "3. install new binary"
install -m 755 -o root -g root "$NEW_BIN" "$BIN"
"$BIN" --version

# set_key SECTION KEY VALUE: replace KEY in [SECTION], or add it right after the section header.
# The value goes through the environment, not argv: argv is visible to every local user via ps.
set_key() {
  VAL="$3" python3 - "$INI" "$1" "$2" <<'PY'
import os, sys, re
path, sec, key = sys.argv[1:4]
val = os.environ["VAL"]
lines = open(path).read().split("\n")
out, cur, done = [], None, False
for i, l in enumerate(lines):
    m = re.match(r"^\[(.+)\]\s*$", l)
    if m:
        if cur == sec and not done:
            out.append(f"{key} = {val}"); done = True
        cur = m.group(1)
    if cur == sec and re.match(rf"^\s*{re.escape(key)}\s*=", l):
        if not done:
            out.append(f"{key} = {val}"); done = True
        continue
    out.append(l)
if not done:
    if cur == sec:
        out.append(f"{key} = {val}")
    else:
        out += ["", f"[{sec}]", f"{key} = {val}"]
open(path, "w").write("\n".join(out))
PY
}

echo "4. close self-registration"
set_key service DISABLE_REGISTRATION true

echo "5. rotate server secrets (values not shown)"
set_key security INTERNAL_TOKEN "$("$BIN" generate secret INTERNAL_TOKEN)"
set_key security SECRET_KEY "$("$BIN" generate secret SECRET_KEY)"
set_key oauth2 JWT_SECRET "$("$BIN" generate secret JWT_SECRET)"
set_key server LFS_JWT_SECRET "$("$BIN" generate secret LFS_JWT_SECRET)"

echo "6. rotate database password"
dbpw="$(openssl rand -base64 36 | tr -d '/+=\n' | cut -c1-40)"
# printf is a shell builtin, so the password reaches psql on stdin and never appears in argv.
printf "ALTER USER gitea WITH PASSWORD '%s';\n" "$dbpw" | sudo -u postgres psql -q -d postgres -v ON_ERROR_STOP=1
set_key database PASSWD "$dbpw"   # alphanumeric only, so no ini quoting needed
unset dbpw
chown root:git "$INI"; chmod 640 "$INI"

echo "7. start gitea (runs database migrations)"
systemctl start gitea
for _ in $(seq 1 60); do
  curl -sf -o /dev/null http://127.0.0.1:3000/api/healthz && break
  sleep 2
done
curl -s http://127.0.0.1:3000/api/v1/version; echo
systemctl is-active gitea
echo "done. Verify, then: shred -u /root/app.ini.bak-$ts"
