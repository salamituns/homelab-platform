#!/bin/bash
# shellcheck disable=SC2016,SC2034  # checks are single-quoted on purpose: ok() evals them later.
# Offline harness for ci/promoters/promote-ghcr.sh: stubbed tools, local git remote, fake Gitea API.
set -uo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$H/../.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/promoter-h.XXXXXX")"
trap 'kill $SRV 2>/dev/null; rm -rf "$W"' EXIT

mkdir -p "$W/bin" "$W/opt" "$W/job"
cp "$SRC/promoters/promote-ghcr.sh" "$SRC/gates/lib.sh" "$W/opt/"
DIG=sha256:$(printf 'a%.0s' $(seq 64))
export CALLS="$W/calls.log"
for t in crane cosign trivy syft; do
  cat >"$W/bin/$t" <<EOF
#!/bin/bash
echo "$t \$*" >>"\$CALLS"
if [ "$t" = crane ] && [ "\$1" = digest ]; then echo "$DIG"; fi
# Like real cosign 3.x: COSIGN_KEY in the environment acts as --key, and --key plus a
# keyless identity flag is an error (build #3, 2026-11-09).
if [ "$t" = cosign ] && [ -n "\${COSIGN_KEY:-}" ] && printf '%s\n' "\$@" | grep -q -- '--certificate-identity'; then
  echo "Error: exactly one of: key reference (--key) or certificate identity" >&2; exit 1
fi
if [ "$t" = cosign ]; then echo '{}'; fi
exit 0
EOF
  chmod +x "$W/bin/$t"
done
printf '#!/bin/bash\necho "sign.sh $*" >>"$CALLS"\n' >"$W/opt/sign.sh"; chmod +x "$W/opt/sign.sh"
# kustomize stub: rewrite the digest line like `kustomize edit set image name=ref@digest`
cat >"$W/bin/kz" <<'EOF'
#!/bin/bash
d="${4##*@}"; perl -pi -e "s/digest: .*/digest: $d/" kustomization.yaml
EOF
chmod +x "$W/bin/kz"

# apps-deploy remote with the staging overlay at zero digest
git init -q --bare "$W/remote.git"
git clone -q "$W/remote.git" "$W/seed" 2>/dev/null
mkdir -p "$W/seed/apps/personal-site/overlays/staging"
cat >"$W/seed/apps/personal-site/overlays/staging/kustomization.yaml" <<'EOF'
images:
  - name: registry.home.arpa/personal-site/site
    newName: registry.home.arpa/personal-site/site
    digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
EOF
(cd "$W/seed" && git add -A && git -c user.name=t -c user.email=t@t commit -qm init && git branch -M main && git push -q origin main)

# fake Gitea: MODE file controls POST result; open PR list kept in prs.json
echo '[]' >"$W/prs.json"; echo 201 >"$W/mode"
python3 "$H/fake_gitea.py" "$W" &
SRV=$!; sleep 1
PORT=$(cat "$W/port")

export PATH="$W/bin:$PATH" SOURCE_REPO=Owner/site.example GHCR_IMAGE=personal-site GIT_URL=https://gitea.home.arpa/tunsgit/homelab-platform.git
export GITEA_URL="http://127.0.0.1:$PORT" PROMOTE_REMOTE="$W/remote.git" KUSTOMIZE_CMD="$W/bin/kz"
export GITEA_PROMOTE_USER=ci-promote GITEA_PROMOTE_TOKEN=x COSIGN_KEY="$W/opt/lib.sh" COSIGN_PASSWORD=x
export TRIVY_CACHE_DIR="$W/cache"

pass=0; fail=0
ok() { if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
run() { : >"$CALLS"; (cd "$W/job" && REPORT_DIR="$W/job/reports" bash "$W/opt/promote-ghcr.sh" "$@" >"$W/out.log" 2>&1); echo $?; }
signs() { grep -c '^sign.sh' "$CALLS"; }
copies() { grep -c '^crane copy' "$CALLS"; }
posts() { cat "$W/posts"; }
: >"$W/posts"

# The Jenkins credential arrives with the file's trailing newline (build #2, 2026-11-09).
rc=$(SOURCE_REPO=$'Owner/site.example\n' run --dry-run)
ok "SOURCE_REPO with trailing newline accepted" '[ "$rc" = 0 ]'

rc=$(run --dry-run)
ok "dry-run exits 0"                      '[ "$rc" = 0 ]'
ok "dry-run: no copy, no sign"            '[ "$(copies)" = 0 ] && [ "$(signs)" = 0 ]'
ok "dry-run: verify flags use repo claim" 'grep -q -- "--certificate-github-workflow-repository Owner/site.example" "$CALLS"'
ok "dry-run: ghcr ref = owner (lowercased) + GHCR_IMAGE, not the repo name" 'grep -q "crane digest ghcr.io/owner/personal-site:main" "$CALLS"'
rc=$(GHCR_IMAGE='' run --dry-run)
ok "GHCR_IMAGE unset is refused"          '[ "$rc" != 0 ] && grep -q "GHCR_IMAGE is unset" "$W/out.log"'

echo 500 >"$W/mode"
rc=$(run)
ok "PR API 500: run fails"                '[ "$rc" != 0 ]'
ok "PR API 500: copied+signed once"       '[ "$(copies)" = 1 ] && [ "$(signs)" = 1 ]'
ok "branch pushed with digest"            'git -C "$W/remote.git" show promote/site-aaaaaaaaaaaa:apps/personal-site/overlays/staging/kustomization.yaml | grep -q "$DIG"'

echo 201 >"$W/mode"
rc=$(run)
ok "retry: exits 0"                       '[ "$rc" = 0 ]'
ok "retry: no re-copy, no re-sign"        '[ "$(copies)" = 0 ] && [ "$(signs)" = 0 ]'
ok "retry: PR created"                    '[ "$(posts | grep -c 201)" = 1 ]'

rc=$(run)
ok "PR open: exits 0, no writes"          '[ "$rc" = 0 ] && [ "$(copies)" = 0 ] && [ "$(signs)" = 0 ]'
ok "PR open: no second PR"                '[ "$(posts | grep -c 201)" = 1 ]'

# simulate the owner merging the promote branch (branch kept)
(cd "$W/seed" && git pull -q origin promote/site-aaaaaaaaaaaa 2>/dev/null && git push -q origin main)
echo '[]' >"$W/prs.json"
rc=$(run)
ok "merged: exits 0"                      '[ "$rc" = 0 ]'
ok "merged: no writes, no PR"             '[ "$(copies)" = 0 ] && [ "$(signs)" = 0 ] && [ "$(posts | grep -c 201)" = 1 ]'
ok "merged: says main already pins"       'grep -q "on main already pins" "$W/out.log"'
ok "repo name never logged"               '! grep -qi "site.example" "$W/out.log"'
echo "TOTAL pass=$pass fail=$fail"
[ "$fail" = 0 ] || { echo "--- last out.log"; cat "$W/out.log"; }
