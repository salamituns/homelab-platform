#!/usr/bin/env bash
# Create the lab CA: an offline name-constrained root plus one intermediate (ADR 0015 section B).
# OWNER runs this on the Mac, offline. The private keys never leave private/ca/ (gitignored,
# 0600, umask 077) and are never printed or passed on a command line; only public certificate
# facts (subject, notAfter, fingerprint) are printed. The root certificate alone is vendored to
# ansible/files/ca/lab-root.crt for the trust stores.
#
# Why name constraints: a root trusted on the Mac could otherwise vouch for any site on the
# internet; constrained to home.arpa its worst case is this lab (ADR 0015 B, with the client
# enforcement evidence).
#
# Design facts from ADR 0015 B: root ECDSA P-256, 10 years, pathlen:1; intermediate ECDSA P-256,
# 5 years, pathlen:0; both carry the critical DNS name constraint permitted;DNS:home.arpa.
#
# Usage:
#   scripts/ca-create-root.sh --dry-run    # show the plan and commands, change nothing
#   scripts/ca-create-root.sh
#
# Env:
#   CA_DIR       default private/ca (gitignored)
#   OPENSSL_BIN  default openssl; must be OpenSSL 3 (the Mac ships LibreSSL, which is NOT used)
#
# Idempotence: refuses to overwrite any existing key or cert, and refuses to run if a different
# root is already vendored. Creating a second root is a deliberate act, not a rerun.
#
# Undo (everything this script creates, all deliberate):
#   rm -P private/ca/lab-root.key private/ca/lab-intermediate.key
#   rm private/ca/lab-root.crt private/ca/lab-intermediate.crt private/ca/lab-root.srl
#   rm ansible/files/ca/lab-root.crt
#   sudo security remove-trusted-cert -d ansible/files/ca/lab-root.crt   # if the keychain step was done
set -euo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CA_DIR="${CA_DIR:-$REPO_ROOT/private/ca}"
VENDORED="$REPO_ROOT/ansible/files/ca/lab-root.crt"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
[[ $# -gt 0 && "$1" != "--dry-run" ]] && { echo "usage: $0 [--dry-run]" >&2; exit 2; }

ROOT_KEY="$CA_DIR/lab-root.key";  ROOT_CRT="$CA_DIR/lab-root.crt"
INT_KEY="$CA_DIR/lab-intermediate.key";  INT_CRT="$CA_DIR/lab-intermediate.crt"
ROOT_DAYS=3650   # 10 years (ADR 0015 B)
INT_DAYS=1825    # 5 years (ADR 0015 B)

# OpenSSL 3 only: LibreSSL (the Mac default) is not tested here, and OpenSSL 3 is what signs
# the subject/authority key identifiers the way this script's extfiles ask for.
if ! "$OPENSSL_BIN" version 2>/dev/null | grep -q '^OpenSSL 3'; then
  echo "error: $OPENSSL_BIN is not OpenSSL 3. The Mac default is LibreSSL." >&2
  echo "  brew install openssl@3 && OPENSSL_BIN=/opt/homebrew/opt/openssl@3/bin/openssl $0" >&2
  exit 1
fi

# The keys must be gitignored before they exist; a key in a tracked path is a leak.
if ( cd "$REPO_ROOT" && ! git check-ignore -q "private/ca/lab-root.key" ); then
  echo "error: private/ca/ is not gitignored in this repo; refusing to write keys there" >&2
  exit 1
fi

# Refuse to overwrite anything from a previous run.
for f in "$ROOT_KEY" "$ROOT_CRT" "$INT_KEY" "$INT_CRT"; do
  if [[ -e "$f" ]]; then
    echo "error: $f already exists; this script never overwrites CA material" >&2
    echo "  if a new CA is really intended, move or delete it first (see Undo in the header)" >&2
    exit 3
  fi
done
if [[ -e "$VENDORED" ]]; then
  echo "error: $VENDORED already exists; a root was vendored before." >&2
  echo "  creating a second root silently would break every client that trusts the first." >&2
  echo "  delete it deliberately (see Undo in the header) if a new root is really intended." >&2
  exit 3
fi

run() {   # in --dry-run, show the command instead of running it; no command carries key material
  if $DRY_RUN; then printf '  %s\n' "$*"; else "$@"; fi
}
note() { if $DRY_RUN; then printf '  (dry-run) %s\n' "$*"; else printf '%s\n' "$*"; fi; }

# Extension configs. They contain no secrets (the name constraint and lifetimes are public
# design facts from the ADR); a temp file keeps them out of the repo.
ROOT_EXT="$(mktemp)"; INT_EXT="$(mktemp)"
trap 'rm -f "$ROOT_EXT" "$INT_EXT"' EXIT
cat >"$ROOT_EXT" <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_root
[dn]
CN = Homelab Platform Root CA 2026
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

echo "Creating the lab CA in $CA_DIR (root ${ROOT_DAYS}d, intermediate ${INT_DAYS}d, both ECDSA P-256,"
echo "name-constrained to home.arpa; ADR 0015 section B)."
run mkdir -p "$CA_DIR"   # through run(): --dry-run must not even create the directory

echo "1/4 root key and self-signed certificate:"
run "$OPENSSL_BIN" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ROOT_KEY"
run "$OPENSSL_BIN" req -x509 -new -key "$ROOT_KEY" -out "$ROOT_CRT" -days "$ROOT_DAYS" -config "$ROOT_EXT"
run chmod 600 "$ROOT_KEY"

echo "2/4 intermediate key, CSR and root-signed certificate:"
run "$OPENSSL_BIN" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$INT_KEY"
run "$OPENSSL_BIN" req -new -key "$INT_KEY" -out "$CA_DIR/lab-intermediate.csr" -subj '/CN=Homelab Platform Intermediate CA 2026'
run "$OPENSSL_BIN" x509 -req -in "$CA_DIR/lab-intermediate.csr" -CA "$ROOT_CRT" -CAkey "$ROOT_KEY" \
  -CAcreateserial -out "$INT_CRT" -days "$INT_DAYS" -extfile "$INT_EXT" -extensions v3_intermediate
run chmod 600 "$INT_KEY"
run rm "$CA_DIR/lab-intermediate.csr"   # the CSR has served its purpose; the cert is the artifact

echo "3/4 verify the chain and the constraint:"
run "$OPENSSL_BIN" verify -CAfile "$ROOT_CRT" "$INT_CRT"
note "constraint check (expect 'Permitted: DNS:home.arpa' in both certs)"

echo "4/4 vendor the public root certificate for the trust stores:"
run cp "$ROOT_CRT" "$VENDORED"
run chmod 644 "$VENDORED"

# Public certificate facts only: subject, notAfter, fingerprint. Never the keys.
if ! $DRY_RUN; then
  for crt in "$ROOT_CRT" "$INT_CRT"; do
    echo "--- $(basename "$crt")"
    "$OPENSSL_BIN" x509 -in "$crt" -noout -subject -enddate -fingerprint -sha256
    "$OPENSSL_BIN" x509 -in "$crt" -noout -text | grep -A2 'Name Constraints' | sed 's/^ *//'
  done
  echo "Root certificate vendored: $VENDORED"
  echo "Next (docs/runbooks/internal-ca.md):"
  echo "  scripts/ca-load-intermediate.sh            # push the intermediate to the cluster"
  echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $VENDORED"
  echo "Record the root and intermediate creation dates in that runbook: root ${ROOT_DAYS}d, intermediate ${INT_DAYS}d."
else
  echo "dry-run: nothing was created; run without --dry-run to generate the CA."
fi
