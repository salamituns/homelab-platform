#!/usr/bin/env bash
# Test harness for scripts/pve-ui-cert.sh: runs the csr and sign steps FOR REAL against a
# THROWAWAY CA in a temp directory, then serves the result with openssl s_server and checks
# that curl trusts it through the throwaway root. A dry run alone missed an OpenSSL syntax
# bug in ca-create-root.sh before; the point of this harness is real execution.
#
# The throwaway CA mirrors the real lab CA exactly where it matters for this test: ECDSA
# P-256, root with critical nameConstraints permitted;DNS:home.arpa, pathlen:1, and a
# pathlen:0 intermediate with the same constraint. The leaf then carries an IP SAN outside
# that DNS-only constraint, so a passing strict verify IS the proof that IP SANs are allowed.
#
# It never touches tuns (PVE_CERT_TEST_DIR turns the "hypervisor" into a local directory;
# install/rollback refuse to run there) and never touches private/ca.
#
# Usage: scripts/pve-ui-cert-test.sh [test-root]
#   test-root defaults to mktemp -d; whatever is passed is DELETED on exit. Pass a throwaway
#   directory, never anything under private/.
set -euo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/pve-ui-cert.sh"
PORT="${PVE_CERT_TEST_PORT:-18443}"   # local s_server port; nothing else uses it

if [[ -z "${OPENSSL_BIN:-}" ]]; then
  if [[ -x /opt/homebrew/opt/openssl@3/bin/openssl ]]; then
    OPENSSL_BIN=/opt/homebrew/opt/openssl@3/bin/openssl
  else
    OPENSSL_BIN=openssl
  fi
fi
if ! "$OPENSSL_BIN" version 2>/dev/null | grep -q '^OpenSSL 3'; then
  echo "error: $OPENSSL_BIN is not OpenSSL 3. The Mac default is LibreSSL." >&2
  echo "  brew install openssl@3 && OPENSSL_BIN=/opt/homebrew/opt/openssl@3/bin/openssl $0" >&2
  exit 1
fi

TEST_ROOT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/pve-cert-test.XXXXXX")}"
S_SERVER_PID=""
KEEP=false   # a failure keeps the throwaway root for debugging (printed); success deletes it
cleanup() {
  if [[ -n "$S_SERVER_PID" ]]; then
    kill "$S_SERVER_PID" 2>/dev/null || true
    wait "$S_SERVER_PID" 2>/dev/null || true
  fi
  if $KEEP; then echo "kept test root for debugging: $TEST_ROOT" >&2
  else rm -rf "$TEST_ROOT"; fi
}
trap cleanup EXIT
echo "Test root (throwaway, deleted on exit): $TEST_ROOT"
mkdir -p "$TEST_ROOT/ca" "$TEST_ROOT/host"

echo "1/6 throwaway CA, same shape as the lab CA (name-constrained root + pathlen:0 intermediate):"
ROOT_EXT="$TEST_ROOT/ca/root-ext.cnf"; INT_EXT="$TEST_ROOT/ca/int-ext.cnf"
cat >"$ROOT_EXT" <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_root
[dn]
CN = Throwaway Test Root CA
[v3_root]
basicConstraints = critical, CA:true, pathlen:1
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
nameConstraints = critical, permitted;DNS:home.arpa
EOF
cat >"$INT_EXT" <<'EOF'
[v3_intermediate]
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
nameConstraints = critical, permitted;DNS:home.arpa
EOF
# The same file names the real CA uses, so pve-ui-cert.sh finds them without code changes.
"$OPENSSL_BIN" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$TEST_ROOT/ca/lab-root.key"
"$OPENSSL_BIN" req -x509 -new -key "$TEST_ROOT/ca/lab-root.key" -out "$TEST_ROOT/ca/lab-root.crt" -days 30 -config "$ROOT_EXT"
"$OPENSSL_BIN" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$TEST_ROOT/ca/lab-intermediate.key"
"$OPENSSL_BIN" req -new -key "$TEST_ROOT/ca/lab-intermediate.key" -out "$TEST_ROOT/ca/int.csr" -subj '/CN=Throwaway Test Intermediate CA'
"$OPENSSL_BIN" x509 -req -in "$TEST_ROOT/ca/int.csr" -CA "$TEST_ROOT/ca/lab-root.crt" -CAkey "$TEST_ROOT/ca/lab-root.key" \
  -CAcreateserial -out "$TEST_ROOT/ca/lab-intermediate.crt" -days 25 -extfile "$INT_EXT" -extensions v3_intermediate
rm "$TEST_ROOT/ca/int.csr"
"$OPENSSL_BIN" verify -CAfile "$TEST_ROOT/ca/lab-root.crt" "$TEST_ROOT/ca/lab-intermediate.crt"

echo "2/6 csr step for real (test host = local directory, key never leaves it):"
PVE_CERT_TEST_DIR="$TEST_ROOT" "$SCRIPT" csr

echo "3/6 sign step for real:"
PVE_CERT_TEST_DIR="$TEST_ROOT" "$SCRIPT" sign

LEAF="$TEST_ROOT/pve-ui/tuns.crt"
CHAIN="$TEST_ROOT/pve-ui/tuns-chain.pem"
KEY="$TEST_ROOT/host/pve-ui-cert/pveproxy-ssl.key"

echo "4/6 strict chain verification (also proves the IP SAN is allowed outside the DNS-only constraint):"
"$OPENSSL_BIN" verify -x509_strict -CAfile "$TEST_ROOT/ca/lab-root.crt" -untrusted "$TEST_ROOT/ca/lab-intermediate.crt" "$LEAF"

echo "5/6 extension checks:"
"$OPENSSL_BIN" x509 -in "$LEAF" -noout -ext subjectAltName,extendedKeyUsage,keyUsage,basicConstraints
"$OPENSSL_BIN" x509 -in "$LEAF" -noout -ext subjectAltName | grep -q 'DNS:proxmox.home.arpa' || { echo 'FAIL: proxmox SAN missing' >&2; exit 1; }
"$OPENSSL_BIN" x509 -in "$LEAF" -noout -ext subjectAltName | grep -q 'DNS:tuns.home.arpa' || { echo 'FAIL: tuns SAN missing' >&2; exit 1; }
"$OPENSSL_BIN" x509 -in "$LEAF" -noout -ext subjectAltName | grep -q 'IP Address:192.168.1.181' || { echo 'FAIL: IP SAN missing' >&2; exit 1; }
"$OPENSSL_BIN" x509 -in "$LEAF" -noout -ext extendedKeyUsage | grep -q 'TLS Web Server Authentication' || { echo 'FAIL: serverAuth EKU missing' >&2; exit 1; }
"$OPENSSL_BIN" x509 -in "$LEAF" -noout -ext keyUsage | grep -q 'Digital Signature' || { echo 'FAIL: digitalSignature keyUsage missing' >&2; exit 1; }
test -s "$KEY" || { echo 'FAIL: host key missing' >&2; exit 1; }
chmod_mode=$(stat -f '%Lp' "$KEY")
[[ "$chmod_mode" == "600" ]] || { echo "FAIL: host key mode is $chmod_mode, expected 600" >&2; exit 1; }
# The chain file is what install ships to tuns: exactly leaf + intermediate, in that order.
n=$(grep -c 'BEGIN CERTIFICATE' "$CHAIN")
[[ "$n" == "2" ]] || { echo "FAIL: chain file has $n certs, expected leaf + intermediate" >&2; exit 1; }
head -1 "$CHAIN" | grep -q 'BEGIN CERTIFICATE'
echo "SANs, EKU, keyUsage, the host key (mode 600) and the chain file (2 certs) all present."

echo "6/6 real TLS handshake: s_server serves leaf + intermediate, curl trusts the throwaway root:"
# -cert takes the LEAF only and -cert_chain the intermediate: s_server does not send extra
# certificates from a combined -cert file, and pveproxy (which serves the whole chain file)
# is mirrored by leaf + -cert_chain here.
"$OPENSSL_BIN" s_server -accept "$PORT" -key "$KEY" -cert "$LEAF" -cert_chain "$TEST_ROOT/ca/lab-intermediate.crt" \
  -www >"$TEST_ROOT/s-server.log" 2>&1 &
S_SERVER_PID=$!
for _ in $(seq 1 25); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  sleep 0.2
done
check_handshake() {   # one name through s_server, trusted by the throwaway root only
  local name="$1" out
  if ! out=$(curl -q -sS -o /dev/null -w '%{http_code}' \
      --cacert "$TEST_ROOT/ca/lab-root.crt" --resolve "$name:$PORT:127.0.0.1" \
      "https://$name:$PORT/" 2>&1); then
    echo "FAIL: $name handshake: $out" >&2; KEEP=true; exit 1
  fi
  [[ "$out" == "200" ]] || { echo "FAIL: $name handshake got HTTP $out" >&2; KEEP=true; exit 1; }
  echo "$name -> $out (chain trusted, name matched)"
}
check_handshake proxmox.home.arpa
check_handshake tuns.home.arpa

echo "ALL CHECKS PASSED (csr, sign, strict verify, SANs, EKU, keyUsage, key custody, handshake)."
