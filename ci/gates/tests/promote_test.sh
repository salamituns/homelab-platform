#!/usr/bin/env bash
# Local proof that promote.sh talks to Gitea the way the Jenkins stage must:
# token not in argv, CR/LF stripped, empty PRs skipped, 422 is not "success".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/promote-tests.XXXXXX")"
cleanup() {
	if [[ -n "${FAKE_PID:-}" ]] && kill -0 "${FAKE_PID}" 2>/dev/null; then
		kill "${FAKE_PID}" 2>/dev/null || true
		wait "${FAKE_PID}" 2>/dev/null || true
	fi
	rm -rf "${WORKDIR}"
}
trap cleanup EXIT

OLD_BE="registry.home.arpa/belleshop/belleshop-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD_FE="registry.home.arpa/belleshop/belleshop-frontend@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
NEW_BE="registry.home.arpa/belleshop/belleshop-backend@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
NEW_FE="registry.home.arpa/belleshop/belleshop-frontend@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
IMAGE_TAG="c3f1304d2f1a"
TOKEN_VALUE="promote-test-token-value"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

ok() {
	printf 'ok  %s\n' "$*"
}

# Token variable must only appear on printf lines so it cannot leak via argv.
if grep -E 'GITEA_PROMOTE_TOKEN' "${ROOT}/promote.sh" | grep -v 'printf' >/dev/null; then
	fail "GITEA_PROMOTE_TOKEN used outside printf in promote.sh"
fi
ok "token var only appears inside printf"

write_overlay() {
	local dest="$1"
	local be="$2"
	local fe="$3"
	mkdir -p "${dest}/overlays/dev"
	cat >"${dest}/overlays/dev/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
images:
  - name: belleshop-backend
    newName: registry.home.arpa/belleshop/belleshop-backend
    digest: ${be##*@}
  - name: belleshop-frontend
    newName: registry.home.arpa/belleshop/belleshop-frontend
    digest: ${fe##*@}
EOF
}

init_remote() {
	local seed="${WORKDIR}/seed"
	rm -rf "${seed}" "${WORKDIR}/remote.git"
	mkdir -p "${seed}"
	write_overlay "${seed}" "${OLD_BE}" "${OLD_FE}"
	git -C "${seed}" init -q -b main
	git -C "${seed}" config user.email "admin@home.arpa"
	git -C "${seed}" config user.name "promote-test"
	git -C "${seed}" add overlays
	git -C "${seed}" commit -q -m "seed overlay"
	git -C "${seed}" init -q --bare "${WORKDIR}/remote.git"
	git -C "${seed}" remote add origin "${WORKDIR}/remote.git"
	git -C "${seed}" push -q origin main
}

write_kustomize_stub() {
	cat >"${WORKDIR}/fake-kustomize" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Invoked as: fake-kustomize edit set image name=repo@sha256:...
python3 - "$@" <<'PY'
import sys
from pathlib import Path

path = Path("kustomization.yaml")
text = path.read_text(encoding="utf-8")
for spec in sys.argv[1:]:
    if "=" not in spec or spec in ("edit", "set", "image"):
        continue
    name, ref = spec.split("=", 1)
    if "@" not in ref:
        continue
    new, digest = ref.rsplit("@", 1)
    lines = text.splitlines()
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped in (f"- name: {name}", f"name: {name}"):
            out.append(line)
            i += 1
            while i < len(lines):
                nxt = lines[i]
                nstrip = nxt.strip()
                if nstrip.startswith("- name:") or (
                    nstrip.startswith("name:") and not nstrip.startswith("name: " + name)
                ):
                    break
                indent = nxt[: len(nxt) - len(nxt.lstrip())]
                if nstrip.startswith("newName:"):
                    out.append(f"{indent}newName: {new}")
                elif nstrip.startswith("digest:"):
                    out.append(f"{indent}digest: {digest}")
                else:
                    out.append(nxt)
                i += 1
            continue
        out.append(line)
        i += 1
    text = "\n".join(out) + "\n"
path.write_text(text, encoding="utf-8")
PY
EOF
	chmod +x "${WORKDIR}/fake-kustomize"
}

start_fake_gitea() {
	local mode="$1"
	if [[ -n "${FAKE_PID:-}" ]] && kill -0 "${FAKE_PID}" 2>/dev/null; then
		kill "${FAKE_PID}" 2>/dev/null || true
		wait "${FAKE_PID}" 2>/dev/null || true
	fi
	FAKE_PID=""
	: >"${WORKDIR}/gitea.log"
	rm -f "${WORKDIR}/gitea.port"
	python3 - "${WORKDIR}" "${mode}" "${IMAGE_TAG}" <<'PY' &
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

workdir, mode, tag = sys.argv[1], sys.argv[2], sys.argv[3]
log_path = os.path.join(workdir, "gitea.log")
port_path = os.path.join(workdir, "gitea.port")
branch = f"promote/{tag}"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _record(self, extra):
        rec = {
            "method": self.command,
            "path": self.path.split("?", 1)[0],
            "authorization": self.headers.get("Authorization"),
        }
        rec.update(extra)
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec) + "\n")

    def _send(self, code, body):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._record({})
        if mode == "exists":
            body = json.dumps([{"number": 3, "head": {"ref": branch}}])
        else:
            body = "[]"
        self._send(200, body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or "0")
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        self._record({"body": raw})
        if mode == "unrelated_422":
            self._send(422, '{"message":"invalid title"}')
        elif mode == "already_exists":
            self._send(422, '{"message":"pull request already exists"}')
        else:
            self._send(201, '{"number": 9}')


httpd = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w", encoding="utf-8") as fh:
    fh.write(str(httpd.server_address[1]))
httpd.serve_forever()
PY
	FAKE_PID=$!
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		[[ -s "${WORKDIR}/gitea.port" ]] && break
		sleep 0.05
	done
	[[ -s "${WORKDIR}/gitea.port" ]] || fail "fake Gitea did not start"
	FAKE_PORT="$(cat "${WORKDIR}/gitea.port")"
}

post_count() {
	python3 - "${WORKDIR}/gitea.log" <<'PY'
import json, sys
n = 0
path = sys.argv[1]
if not __import__("os").path.exists(path):
    print(0)
    raise SystemExit
for line in open(path, encoding="utf-8"):
    rec = json.loads(line)
    if rec.get("method") == "POST":
        n += 1
print(n)
PY
}

last_auth() {
	python3 - "${WORKDIR}/gitea.log" <<'PY'
import json, sys
auth = ""
for line in open(sys.argv[1], encoding="utf-8"):
    rec = json.loads(line)
    if rec.get("authorization"):
        auth = rec["authorization"]
print(auth)
PY
}

run_promote() {
	local work="$1"
	mkdir -p "${work}"
	printf 'belleshop-backend=%s\nbelleshop-frontend=%s\n' "${2}" "${3}" >"${work}/digests.txt"
	(
		cd "${work}"
		env -u GIT_DIR -u GIT_WORK_TREE \
			IMAGE_TAG="${IMAGE_TAG}" \
			GIT_URL="https://gitea.home.arpa/ci-owner/BelleShop.git" \
			GIT_COMMIT="c3f1304d2f1a0123456789abcdef" \
			BUILD_URL="https://jenkins.home.arpa/job/belleshop/8/" \
			GITEA_URL="http://127.0.0.1:${FAKE_PORT}" \
			PROMOTE_REMOTE="${WORKDIR}/remote.git" \
			GITEA_PROMOTE_USER="ci-promote" \
			GITEA_PROMOTE_TOKEN="${4}" \
			KUSTOMIZE_CMD="${WORKDIR}/fake-kustomize" \
			"${ROOT}/promote.sh" "${work}/digests.txt"
	)
}

write_kustomize_stub

# --- 201 create ---
init_remote
start_fake_gitea create
run_work="${WORKDIR}/run-create"
if ! out="$(run_promote "${run_work}" "${NEW_BE}" "${NEW_FE}" "${TOKEN_VALUE}"$'\n' 2>&1)"; then
	printf '%s\n' "${out}" >&2
	fail "create PR was expected to pass"
fi
[[ "$(post_count)" -eq 1 ]] || fail "create: expected 1 POST, got $(post_count)"
auth="$(last_auth)"
[[ "${auth}" == "token ${TOKEN_VALUE}" ]] || fail "create: Authorization was [${auth}]"
ok "creates PR (201); token newline stripped from Authorization"

# --- skip unchanged ---
init_remote
start_fake_gitea create
run_work="${WORKDIR}/run-skip"
if ! out="$(run_promote "${run_work}" "${OLD_BE}" "${OLD_FE}" "${TOKEN_VALUE}" 2>&1)"; then
	printf '%s\n' "${out}" >&2
	fail "unchanged overlay was expected to skip (exit 0)"
fi
printf '%s' "${out}" | grep -q 'skip empty PR' || fail "unchanged overlay did not log skip"
[[ "$(post_count)" -eq 0 ]] || fail "skip: expected 0 POST, got $(post_count)"
ok "skips when digests unchanged (no API create)"

# --- existing open PR ---
init_remote
start_fake_gitea exists
run_work="${WORKDIR}/run-exists"
if ! out="$(run_promote "${run_work}" "${NEW_BE}" "${NEW_FE}" "${TOKEN_VALUE}" 2>&1)"; then
	printf '%s\n' "${out}" >&2
	fail "existing PR was expected to pass"
fi
printf '%s' "${out}" | grep -q 'already open' || fail "existing PR did not log branch updated"
[[ "$(post_count)" -eq 0 ]] || fail "existing PR: expected 0 POST, got $(post_count)"
ok "existing open PR updates branch, no create"

# --- 422 with other message ---
init_remote
start_fake_gitea unrelated_422
run_work="${WORKDIR}/run-422"
rc=0
out="$(run_promote "${run_work}" "${NEW_BE}" "${NEW_FE}" "${TOKEN_VALUE}" 2>&1)" || rc=$?
[[ "${rc}" -ne 0 ]] || fail "unrelated 422 was expected to fail"
printf '%s' "${out}" | grep -q 'invalid title' || fail "unrelated 422 did not print body"
printf '%s' "${out}" | grep -q 'already exists' && fail "unrelated 422 was treated as already-exists"
ok "422 with other message fails and prints body"

printf 'all promote tests passed\n'
