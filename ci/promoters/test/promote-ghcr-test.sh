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
# Different fake digest per app so payload checks cannot pass on the wrong app.
DIG=sha256:$(printf 'a%.0s' $(seq 64))
DIG_GOV=sha256:$(printf 'b%.0s' $(seq 64))
export CALLS="$W/calls.log"
for t in crane cosign trivy syft; do
  cat >"$W/bin/$t" <<EOF
#!/bin/bash
echo "$t \$*" >>"\$CALLS"
# crane copy records its destination; a digest lookup of a lab TAG (":promoted-") only
# answers once that tag was copied, like a real registry.
if [ "$t" = crane ] && [ "\$1" = copy ]; then echo "\$3" >>"\$CALLS.copied"; fi
if [ "$t" = crane ] && [ "\$1" = digest ] && [[ "\$2" == *registry.home.arpa*:promoted-* ]]; then
  grep -qxF -- "\$2" "\$CALLS.copied" 2>/dev/null || exit 1
fi
if [ "$t" = crane ] && [ "\$1" = digest ]; then
  case "\$2" in
    *govgraph*) echo "$DIG_GOV" ;;
    *) echo "$DIG" ;;
  esac
fi
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
# Like real kustomize 5.x: rewrites the images list with keys sorted, so "- digest:" comes
# first and "name:" second (2026-11-09: the old in-place edit hid a parser bug).
# $4 is NAME=REF@DIGEST
d="${4##*@}"; n="${4%%=*}"; r="${4#*=}"; ref="${r%@*}"
python3 - "$d" "$n" "$ref" <<'PY'
import sys
d, n, ref = sys.argv[1], sys.argv[2], sys.argv[3]
s = open("kustomization.yaml").read()
head = s.split("images:")[0]
open("kustomization.yaml", "w").write(head + "images:\n- digest: " + d + "\n  name: " + n + "\n  newName: " + ref + "\n")
PY
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
ok "dry-run: verify flags pin the workflow" 'grep -q "lab-release" "$CALLS"'
ok "dry-run: log names the workflow"      'grep -q "workflow lab-release.yml@main" "$W/out.log"'
ok "dry-run: ghcr ref = owner (lowercased) + GHCR_IMAGE, not the repo name" 'grep -q "crane digest ghcr.io/owner/personal-site:main" "$CALLS"'
rc=$(GHCR_IMAGE='' run --dry-run)
ok "GHCR_IMAGE unset is refused"          '[ "$rc" != 0 ] && grep -q "GHCR_IMAGE is unset" "$W/out.log"'
rc=$(GHCR_WORKFLOW='Bad_Name.yml' run --dry-run)
ok "GHCR_WORKFLOW invalid is refused"     '[ "$rc" != 0 ] && grep -q "GHCR_WORKFLOW is not a valid workflow file name" "$W/out.log"'
rc=$(GHCR_WORKFLOW=govgraph-release.yml run --dry-run)
ok "custom workflow reaches the identity flags" 'grep -q "workflows/govgraph-release" "$CALLS"'
ok "custom workflow reaches the log"     'grep -q "workflow govgraph-release.yml@main" "$W/out.log"'

echo 500 >"$W/mode"
rc=$(run)
ok "PR API 500: run fails"                '[ "$rc" != 0 ]'
ok "PR API 500: copied+signed once"       '[ "$(copies)" = 1 ] && [ "$(signs)" = 1 ]'
# Nexus app repos have redeploy disabled: a bare/":latest" destination works once, then
# REDEPLOY_DISABLED forever (govgraph builds #46-#53, 2026-11-13). Copy to a per-digest tag.
ok "copy goes to a per-digest tag"        'grep -qx "crane copy ghcr.io/owner/personal-site@$DIG registry.home.arpa/personal-site/site:promoted-${DIG#sha256:}" "$CALLS"'
# "sha256-<hex>" is the OCI referrers fallback tag cosign writes to (build #56).
ok "copy avoids the referrers fallback tag" '! grep -E "^crane copy .*:sha256-[0-9a-f]+$" "$CALLS"'
ok "copy never targets the default tag"   '! grep -E "^crane copy .* registry.home.arpa/[^ :@]+/[^ :@]+(:latest)?$" "$CALLS"'
ok "branch pushed with digest"            'git -C "$W/remote.git" show promote/site-aaaaaaaaaaaa:apps/personal-site/overlays/staging/kustomization.yaml | grep -q "$DIG"'

echo 201 >"$W/mode"
rc=$(run)
ok "retry: exits 0"                       '[ "$rc" = 0 ]'
ok "retry: no re-copy, no re-sign"        '[ "$(copies)" = 0 ] && [ "$(signs)" = 0 ]'
ok "retry: PR created"                    '[ "$(posts | grep -c 201)" = 1 ]'
ok "site PR head is the pushed branch"    'grep -q "\"head\": \"promote/site-aaaaaaaaaaaa\"" "$W/posts"'
ok "site PR title names the app"          'grep -q "\"title\": \"promote personal-site aaaaaaaaaaaa\"" "$W/posts"'
ok "site PR body names the app image"     'grep -q "registry.home.arpa/personal-site/site@$DIG" "$W/posts"'
ok "site PR body names the workflow"      'grep -q "workflow lab-release.yml@main" "$W/posts"'

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

# Second app: GHCR_IMAGE=govgraph, dest registry.home.arpa/govgraph/web (personal-site defaults stay).
mkdir -p "$W/seed/apps/govgraph/overlays/staging"
cat >"$W/seed/apps/govgraph/overlays/staging/kustomization.yaml" <<'EOF'
images:
  - name: registry.home.arpa/govgraph/web
    newName: registry.home.arpa/govgraph/web
    digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
EOF
(cd "$W/seed" && git add -A && git -c user.name=t -c user.email=t@t commit -qm govgraph-overlay && git push -q origin main)
echo '[]' >"$W/prs.json"
echo 201 >"$W/mode"
: >"$W/posts"
export GHCR_IMAGE=govgraph DEST_IMAGE=registry.home.arpa/govgraph/web
export OVERLAY_DIR=apps/govgraph/overlays/staging
export PROMOTE_APP=govgraph PROMOTE_BRANCH_PREFIX=govgraph
rc=$(run --dry-run)
ok "govgraph dry-run exits 0"             '[ "$rc" = 0 ]'
ok "govgraph dry-run: GHCR package is govgraph, not personal-site" 'grep -q "crane digest ghcr.io/owner/govgraph:main" "$CALLS"'
ok "govgraph dry-run: no copy"           '[ "$(copies)" = 0 ]'
ok "govgraph digest differs from personal-site" '[ "$DIG" != "$DIG_GOV" ]'
rc=$(run)
ok "govgraph promote exits 0"            '[ "$rc" = 0 ]'
ok "govgraph copied once"                '[ "$(copies)" = 1 ]'
ok "govgraph branch prefix is govgraph"  'git -C "$W/remote.git" show promote/govgraph-bbbbbbbbbbbb:apps/govgraph/overlays/staging/kustomization.yaml | grep -q "$DIG_GOV"'
ok "govgraph commit names the app"       'git -C "$W/remote.git" log promote/govgraph-bbbbbbbbbbbb -1 --format=%s | grep -q "promote govgraph"'
ok "govgraph PR head is the pushed branch" 'grep -q "\"head\": \"promote/govgraph-bbbbbbbbbbbb\"" "$W/posts"'
ok "govgraph PR title names the app"     'grep -q "\"title\": \"promote govgraph bbbbbbbbbbbb\"" "$W/posts"'
ok "govgraph PR body names the app image" 'grep -q "registry.home.arpa/govgraph/web@$DIG_GOV" "$W/posts"'
ok "govgraph PR body names the workflow" 'grep -q "workflow lab-release.yml@main" "$W/posts"'
ok "govgraph repo name never logged"     '! grep -qi "site.example" "$W/out.log"'

# Copy done but the run died before the PR (e.g. sign or push failed): the retry finds the
# per-digest tag already holding the digest and must not copy again (that PUT is refused).
git -C "$W/remote.git" branch -q -D promote/govgraph-bbbbbbbbbbbb
echo '[]' >"$W/prs.json"
: >"$W/posts"
rc=$(run)
ok "tag already copied: exits 0"          '[ "$rc" = 0 ]'
ok "tag already copied: no second copy"   '[ "$(copies)" = 0 ] && [ "$(signs)" = 1 ]'
ok "tag already copied: says so"          'grep -q "already holds this digest; not copying again" "$W/out.log"'
ok "tag already copied: PR still opened"  '[ "$(posts | grep -c 201)" = 1 ]'
echo "TOTAL pass=$pass fail=$fail"
[ "$fail" = 0 ] || { echo "--- last out.log"; cat "$W/out.log"; }
