#!/usr/bin/env bash
# ADR 0005: move repos from the old Gitea (UbuntuNew) to the rebuilt one, git data only.
# Each repo is mirrored to this Mac, verified (git fsck, gitleaks), then pushed to a new private repo.
# Nothing else crosses over: no database, no hooks, no repo config, no accounts, no tokens.
#
# Run from the repo root on the home LAN:
#   set -a; . ./.envrc; set +a                # GITEA_TOKEN = token on the OLD server
#   read -rs -p "new Gitea migration token: " NEW_GITEA_TOKEN; echo; export NEW_GITEA_TOKEN
#   scripts/migrate-gitea-repos.sh
# The new-server token needs write:repository and write:user (to create repos). Delete it afterwards.
set -euo pipefail

OLD_URL="${OLD_URL:-http://ubuntunew.home.arpa:3000}"
NEW_URL="${NEW_URL:-https://gitea.home.arpa}"
OWNER="${OWNER:-tunsgit}"
CA="${CA:-ansible/files/ca/gitea-caddy-root.crt}"   # Caddy internal root, fetched by the gitea role
WORK="${WORK:-$(mktemp -d)}"

: "${GITEA_TOKEN:?old-server token missing (source .envrc)}"
: "${NEW_GITEA_TOKEN:?new-server token missing (read -rs NEW_GITEA_TOKEN)}"
[ -f "$CA" ] || { echo "missing $CA (run playbooks/gitea.yml first)" >&2; exit 1; }

# curl -q: ignore ~/.curlrc (an "-k" there would silently disable --cacert).
# Tokens reach git through a credential helper reading the environment: never in URLs, argv or .git/config.
old_git() { git -c credential.helper= -c credential.helper='!f(){ echo username='"$OWNER"'; echo "password=$GITEA_TOKEN"; }; f' "$@"; }
new_git() { git -c credential.helper= -c credential.helper='!f(){ echo username='"$OWNER"'; echo "password=$NEW_GITEA_TOKEN"; }; f' \
               -c http.sslCAInfo="$CA" "$@"; }
new_api() { curl -q -sS --fail-with-body --cacert "$CA" -H "Authorization: token $NEW_GITEA_TOKEN" \
               -H "Content-Type: application/json" "$@"; }

# repos/search, not user/repos: the latter needs read:user, which the laptop token deliberately lacks.
repos=$(curl -q -sS --fail -H "Authorization: token $GITEA_TOKEN" "$OLD_URL/api/v1/repos/search?limit=50" |
  python3 -c 'import sys,json; [print(r["name"]) for r in json.load(sys.stdin)["data"] if r["owner"]["login"]=="'"$OWNER"'"]')
[ -n "$repos" ] || { echo "no repos found on old server" >&2; exit 1; }
echo "repos on old server: $(echo "$repos" | tr '\n' ' ')"
echo "work dir: $WORK"

for r in $repos; do
  echo "== $r"
  d="$WORK/$r.git"
  old_git clone -q --mirror "$OLD_URL/$OWNER/$r.git" "$d"

  # Verify before anything is pushed: object integrity, and no attacker refs.
  git --git-dir="$d" fsck --full --no-progress >/dev/null
  if git --git-dir="$d" for-each-ref --format='%(refname)' | grep -q 'rce-proof'; then
    echo "ABORT: $r has an rce-proof ref" >&2; exit 1
  fi
  # Secrets in history are reported, not blocking: tokens found here were revoked 2026-10-25.
  gitleaks git "$d" --no-banner --redact -l warn 2>&1 | grep -E 'leaks found|no leaks' || true

  desc=$(curl -q -sS -H "Authorization: token $GITEA_TOKEN" "$OLD_URL/api/v1/repos/$OWNER/$r" |
    python3 -c 'import sys,json; print(json.load(sys.stdin).get("description",""))')
  if new_api -o /dev/null "$NEW_URL/api/v1/repos/$OWNER/$r" 2>/dev/null; then
    echo "   exists on new server"
  else
    python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"description":sys.argv[2],"private":True}))' "$r" "$desc" |
      new_api -o /dev/null -X POST "$NEW_URL/api/v1/user/repos" --data @-
    echo "   created (private)"
  fi

  # Only branches and tags: refs/pull/* and other server-side refs stay behind.
  new_git --git-dir="$d" push -q --prune "$NEW_URL/$OWNER/$r.git" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'

  # Prove the copy: same refs on both sides.
  a=$(git --git-dir="$d" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags | sort)
  b=$(new_git ls-remote "$NEW_URL/$OWNER/$r.git" 'refs/heads/*' 'refs/tags/*' | awk '{print $1" "$2}' | grep -v '\^{}' | sort)
  [ "$a" = "$b" ] && echo "   verified: $(echo "$a" | wc -l | tr -d ' ') refs match" || { echo "MISMATCH in $r" >&2; exit 1; }
done
echo "done. Delete the migration token on the new server, and: rm -rf $WORK"
