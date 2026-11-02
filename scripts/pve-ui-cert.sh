#!/usr/bin/env bash
# The Proxmox UI certificate (ADR 0015 section B, "Proxmox UI"): a lab-CA leaf for pveproxy on
# tuns, with the private key generated ON the hypervisor and never leaving it. OWNER runs this.
#
# Why this shape (ADR 0015 B): the web UI on :8006 serves the node certificate signed by PVE's
# own cluster CA, which no client trusts. ACME is ruled out (home.arpa is not publicly
# resolvable, so http-01/dns-01 cannot validate). So: the key is generated on tuns, only the
# CSR crosses to the Mac, the owner signs it with the lab CA, and only the public chain goes
# back. A Certificate object in Kubernetes was deliberately rejected: it would put the
# hypervisor's private key inside the cluster and force a hand export at every renewal.
#
# DEVIATION from ADR 0015 (recorded there as "Implementation note 2026-11-02"): the leaf is
# signed by the lab INTERMEDIATE, not the offline root, so the root key stays untouched. Same
# trust chain for clients (root -> intermediate -> leaf, both constrain names to home.arpa),
# one deliberate root-key use less.
#
# Custody rules: the hypervisor key never leaves tuns and is never printed; the intermediate
# key on the Mac is read only by openssl, never printed, never on a command line. pvenode is
# called with the KEY PRE-STAGED at /etc/pve/local/pveproxy-ssl.key and only the public chain
# on the command line: PVE accepts cert set without the key argument when the key file already
# exists (PVE::API2::Certificates upload_custom_cert, verified on PVE 9.1.2), so the key never
# appears in a process list.
#
# Usage (each step separately, in order; --dry-run shows the plan and creates nothing):
#   scripts/pve-ui-cert.sh csr --dry-run
#   scripts/pve-ui-cert.sh csr          # key + CSR on tuns, CSR copied back to the Mac
#   scripts/pve-ui-cert.sh sign         # leaf + chain on the Mac, strictly verified
#   scripts/pve-ui-cert.sh install      # chain to tuns, pvenode cert set, verify from the Mac
#   scripts/pve-ui-cert.sh rollback     # pvenode cert delete, default PVE certificate back
#
# Env:
#   OPENSSL_BIN       default /opt/homebrew/opt/openssl@3/bin/openssl when present, else
#                     openssl; must be OpenSSL 3 (the Mac default is LibreSSL)
#   PVE_HOST          default tuns (root SSH, BatchMode, key only)
#   CA_DIR            default private/ca (gitignored); lab root + intermediate
#   PVE_UI_DIR        default private/pve-ui (gitignored); CSR, leaf and chain land here
#   PVE_CERT_TEST_DIR test mode ONLY, used by scripts/pve-ui-cert-test.sh: the "hypervisor"
#                     becomes a local directory and the CA a throwaway in it; install and
#                     rollback refuse to run. Nothing here is for production use.
#
# Renewal: the leaf lives 825 days (macOS rejects TLS leaves over 825 days, even from a
# user-trusted CA: CSSMERR_TP_CERT_SUSPENDED, seen 2026-11-02); docs/runbooks/proxmox-ui-cert.md records the issue date
# and the 30-month reminder. Reissue = csr is NOT needed (the key on tuns is reused): sign +
# install again, after moving the old leaf/chain aside (this script never overwrites them).
#
# Undo (full ordered rollback in docs/runbooks/proxmox-ui-cert.md):
#   scripts/pve-ui-cert.sh rollback        # pvenode cert delete 1, pveproxy back to node cert
#   ssh tuns 'rm -rf /root/pve-ui-cert'    # the key and CSR on the hypervisor
#   rm private/pve-ui/tuns.csr private/pve-ui/tuns.crt private/pve-ui/tuns-chain.pem
set -euo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PVE_HOST="${PVE_HOST:-tuns}"
TEST_ROOT="${PVE_CERT_TEST_DIR:-}"

# Test mode rewires the defaults BEFORE they are used; every path below then stays inside
# TEST_ROOT and tuns is never contacted.
if [[ -n "$TEST_ROOT" ]]; then
  CA_DIR="${CA_DIR:-$TEST_ROOT/ca}"
  PVE_UI_DIR="${PVE_UI_DIR:-$TEST_ROOT/pve-ui}"
  HDIR="$TEST_ROOT/host/pve-ui-cert"      # the "hypervisor" side, locally
  HOST_OPENSSL='unset'                    # filled after the OpenSSL gate below
else
  CA_DIR="${CA_DIR:-$REPO_ROOT/private/ca}"
  PVE_UI_DIR="${PVE_UI_DIR:-$REPO_ROOT/private/pve-ui}"
  HDIR="/root/pve-ui-cert"                # on tuns; root-only, never leaves the hypervisor
  HOST_OPENSSL='openssl'                  # tuns runs OpenSSL 3.5.7 (verified 2026-11-02)
fi
VENDORED_ROOT="$REPO_ROOT/ansible/files/ca/lab-root.crt"

DRY_RUN=false
cmd=""
for a in "$@"; do
  if [[ "$a" == "--dry-run" ]]; then DRY_RUN=true
  elif [[ -z "$cmd" ]]; then cmd="$a"
  else echo "usage: $0 <csr|sign|install|rollback> [--dry-run]" >&2; exit 2
  fi
done
case "$cmd" in
  csr|sign|install|rollback) ;;
  *) echo "usage: $0 <csr|sign|install|rollback> [--dry-run]" >&2; exit 2 ;;
esac

# OpenSSL 3 only (same gate as scripts/ca-create-root.sh): LibreSSL is the Mac default and is
# not what signs and verifies here. In test mode the same binary plays the hypervisor role.
if [[ -z "${OPENSSL_BIN:-}" ]]; then
  if [[ -x /opt/homebrew/opt/openssl@3/bin/openssl ]]; then
    OPENSSL_BIN=/opt/homebrew/opt/openssl@3/bin/openssl
  else
    OPENSSL_BIN=openssl
  fi
fi
if ! "$OPENSSL_BIN" version 2>/dev/null | grep -q '^OpenSSL 3'; then
  echo "error: $OPENSSL_BIN is not OpenSSL 3. The Mac default is LibreSSL." >&2
  echo "  brew install openssl@3 && OPENSSL_BIN=/opt/homebrew/opt/openssl@3/bin/openssl $0 $cmd" >&2
  exit 1
fi
[[ -n "$TEST_ROOT" ]] && HOST_OPENSSL="$OPENSSL_BIN"

# Nothing this script writes locally may be committable: the CSR is public but belongs to the
# owner only, and the leaf/chain path sits next to it. (Test mode writes only inside TEST_ROOT.)
if [[ -z "$TEST_ROOT" && ( "$cmd" == "csr" || "$cmd" == "sign" ) ]]; then
  rel="${PVE_UI_DIR#"$REPO_ROOT"/}"
  if ( cd "$REPO_ROOT" && ! git check-ignore -q "$rel/tuns.csr" ); then
    echo "error: $rel is not gitignored in this repo; refusing to write there" >&2
    exit 1
  fi
fi

run() {   # in --dry-run, show the command instead of running it; no command carries key material
  if $DRY_RUN; then printf '  %s\n' "$*"; else "$@"; fi
}
note() { if $DRY_RUN; then printf '  (dry-run) %s\n' "$*"; else printf '%s\n' "$*"; fi; }
host_exec() {   # run a shell snippet "on the hypervisor" (locally in test mode); prints in dry-run
  if $DRY_RUN; then
    if [[ -n "$TEST_ROOT" ]]; then printf '  (test host) bash -c: %s\n' "$1"
    else printf '  ssh %s: %s\n' "$PVE_HOST" "$1"; fi
  else
    if [[ -n "$TEST_ROOT" ]]; then bash -c "$1"
    else ssh -o BatchMode=yes "$PVE_HOST" "$1"; fi
  fi
}

CSR="$PVE_UI_DIR/tuns.csr"
LEAF="$PVE_UI_DIR/tuns.crt"
CHAIN="$PVE_UI_DIR/tuns-chain.pem"
INT_CRT="$CA_DIR/lab-intermediate.crt"
INT_KEY="$CA_DIR/lab-intermediate.key"
ROOT_CRT="$CA_DIR/lab-root.crt"
LEAF_DAYS=825    # Apple's maximum for TLS server certs; reminder at 24 months in the runbook

cmd_csr() {
  # 1. key + CSR on the hypervisor: umask 077, refuse to overwrite, key never printed and
  #    never copied back. The CSR subject is fixed here because x509 -req carries it into the
  #    leaf; sign refuses a CSR that says anything else.
  host_exec "umask 077
    if [ -e '$HDIR/pveproxy-ssl.key' ]; then echo 'error: $HDIR/pveproxy-ssl.key already exists; this script never overwrites key material' >&2; exit 3; fi
    $HOST_OPENSSL version | grep -q '^OpenSSL 3' || { echo 'error: host openssl is not OpenSSL 3' >&2; exit 1; }
    mkdir -p '$HDIR'
    $HOST_OPENSSL genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out '$HDIR/pveproxy-ssl.key'
    $HOST_OPENSSL req -new -key '$HDIR/pveproxy-ssl.key' -out '$HDIR/tuns.csr' -subj '/CN=proxmox.home.arpa'
    chmod 600 '$HDIR/pveproxy-ssl.key'"

  # 2. copy back ONLY the CSR. The key stays on the hypervisor for the install step.
  if $DRY_RUN; then
    note "fetch the CSR back: cat $HDIR/tuns.csr > $CSR (only the CSR crosses; the key never does)"
  else
    mkdir -p "$PVE_UI_DIR"
    host_exec "cat '$HDIR/tuns.csr'" > "$CSR"
    note "CSR saved: $CSR (the key stayed on the hypervisor side)"
  fi
}

cmd_sign() {
  # Preconditions and the never-overwrite rule, like scripts/ca-create-root.sh. In --dry-run a
  # missing input is only noted, so the plan can be shown before the csr step has run.
  for f in "$CSR" "$INT_CRT" "$INT_KEY" "$ROOT_CRT"; do
    if [[ ! -f "$f" ]]; then
      if $DRY_RUN; then note "missing input (fine for a dry run, required for the real one): $f"
      else echo "error: $f is missing (csr step first / CA not created)" >&2; exit 1; fi
    fi
  done
  for f in "$LEAF" "$CHAIN"; do
    [[ -e "$f" ]] && { echo "error: $f already exists; this script never overwrites cert material" >&2
      echo "  move it aside first (renewal: see the header and the runbook)" >&2; exit 3; }
  done
  # The leaf subject comes from the CSR (x509 -req works that way), so insist it is exactly
  # the one the csr step sets. SAN, EKU, keyUsage and CA:false come from the extfile below
  # only; -copy_extensions is never passed, so nothing else in the CSR is honored.
  if [[ -f "$CSR" ]] && ! "$OPENSSL_BIN" req -in "$CSR" -noout -subject | grep -q 'CN *= *proxmox\.home\.arpa'; then
    echo "error: $CSR has an unexpected subject; refusing to sign (the script sets the name)" >&2
    exit 1
  fi

  # Extension config: no secrets (names and lifetimes are public design facts from the ADR).
  # The IP SAN is deliberately outside the CA name constraints: those permit DNS:home.arpa
  # only, and RFC 5280 name constraints apply per name form, so an IP SAN is unrestricted
  # when no IP subtree is listed. The strict verify below proves it.
  EXT="$(mktemp)"
  trap 'rm -f "$EXT"' EXIT
  cat >"$EXT" <<'EOF'
[v3_leaf]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:proxmox.home.arpa,DNS:tuns.home.arpa,IP:192.168.1.181
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

  # Sign with the intermediate (the deviation in the header): 825-day leaf, SHA-256.
  run "$OPENSSL_BIN" x509 -req -in "$CSR" -CA "$INT_CRT" -CAkey "$INT_KEY" -CAcreateserial \
    -out "$LEAF" -days "$LEAF_DAYS" -sha256 -extfile "$EXT" -extensions v3_leaf
  # The chain clients need: leaf + intermediate (the root is already in the trust stores).
  if $DRY_RUN; then
    note "cat $LEAF $INT_CRT > $CHAIN"
  else
    cat "$LEAF" "$INT_CRT" > "$CHAIN"
  fi

  # Strict RFC 5280 verification against the root through the intermediate; a failure removes
  # what was just produced so a bad leaf is never left around.
  if ! run "$OPENSSL_BIN" verify -x509_strict -CAfile "$ROOT_CRT" -untrusted "$INT_CRT" "$LEAF"; then
    if ! $DRY_RUN; then rm -f "$LEAF" "$CHAIN"; fi
    echo "error: strict chain verification failed; nothing was kept" >&2
    exit 1
  fi

  # Public certificate facts only: subject, SAN, notAfter, fingerprint. Record the date in
  # docs/runbooks/proxmox-ui-cert.md (renewal reminder at 24 months).
  if ! $DRY_RUN; then
    "$OPENSSL_BIN" x509 -in "$LEAF" -noout -subject -enddate -fingerprint -sha256
    "$OPENSSL_BIN" x509 -in "$LEAF" -noout -ext subjectAltName,extendedKeyUsage
    echo "Chain (leaf + intermediate): $CHAIN"
  else
    echo "dry-run: nothing was created; run without --dry-run to sign."
  fi
}

cmd_install() {
  if [[ -n "$TEST_ROOT" ]]; then
    echo "error: install never runs in test mode (it would touch tuns)" >&2; exit 1
  fi
  if [[ ! -f "$CHAIN" ]]; then
    if $DRY_RUN; then note "missing input (fine for a dry run, required for the real one): $CHAIN"
    else echo "error: $CHAIN is missing (sign step first)" >&2; exit 1; fi
  fi

  echo "1/4 copy the public chain to tuns (the key never travels; it is already there):"
  if $DRY_RUN; then
    note "ssh $PVE_HOST 'cat > $HDIR/pveproxy-ssl-chain.pem' < $CHAIN"
  else
    ssh -o BatchMode=yes "$PVE_HOST" "cat > '$HDIR/pveproxy-ssl-chain.pem'" < "$CHAIN"
  fi

  echo "2/4 pre-stage the key at the pveproxy path so pvenode needs no key argument"
  echo "    (PVE: cert set accepts certificates alone when the key file exists):"
  host_exec "test -f '$HDIR/pveproxy-ssl.key' || { echo 'error: $HDIR/pveproxy-ssl.key missing (csr step first)' >&2; exit 1; }
    cat '$HDIR/pveproxy-ssl.key' > /etc/pve/local/pveproxy-ssl.key"
  # pmxcfs (/etc/pve) sets 0640 root:www-data itself and may refuse chmod/chown, so no install -m/-o/-g.

  echo "3/4 pvenode cert set with the public chain only (--force overwrites the default,"
  echo "    --restart 1 reloads pveproxy; the chain is a file path):"
  host_exec "pvenode cert set '$HDIR/pveproxy-ssl-chain.pem' --force 1 --restart 1"
  # pvenode maps <certificates> and <key> to FILE PATHS and reads them itself
  # (PVE::CLI::pvenode mapping -> RESTHandler file_get_contents), so pass the path, not the PEM text.

  echo "4/4 verify from the Mac (lab root as trust anchor; DNS via the lab resolver):"
  # /usr/bin/curl, not whatever is first on PATH (conda ships its own); pveproxy needs a few
  # seconds after the restart, so retry for up to ~30s before reporting.
  wait_https() {
    local name=$1 code=000 i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      code=$(/usr/bin/curl -q -s -o /dev/null -m 5 -w '%{http_code}' --cacert "$VENDORED_ROOT" \
        --resolve "$name:8006:192.168.1.181" "https://$name:8006/") || true
      [ "$code" != 000 ] && break
      sleep 3
    done
    echo "$name:8006 -> $code"
  }
  if $DRY_RUN; then
    note "/usr/bin/curl --cacert $VENDORED_ROOT https://proxmox.home.arpa:8006/ and https://tuns.home.arpa:8006/ (retry ~30s)"
    note "security verify-cert -p ssl -s proxmox.home.arpa (macOS trust, the browser's view)"
  else
    wait_https proxmox.home.arpa
    wait_https tuns.home.arpa
    echo "    macOS trust check (what Safari/Chrome use; expect 'successful'):"
    security verify-cert -c "$LEAF" -c "$CA_DIR/lab-intermediate.crt" -p ssl -s proxmox.home.arpa 2>&1 \
      | grep -E 'Cert Verify Result|successful' || true
  fi
  echo "    issuer check (expect the lab intermediate and verify ok):"
  run "$OPENSSL_BIN" s_client -connect 192.168.1.181:8006 -servername proxmox.home.arpa \
    -CAfile "$VENDORED_ROOT" </dev/null
  note "if anything failed: scripts/pve-ui-cert.sh rollback, then investigate before retrying"
}

cmd_rollback() {
  if [[ -n "$TEST_ROOT" ]]; then
    echo "error: rollback never runs in test mode (it would touch tuns)" >&2; exit 1
  fi
  # PVE 9 syntax note: cert delete takes restart as a POSITIONAL boolean (usage:
  # "pvenode cert delete [<restart>]"), unlike cert set where --restart is a named option.
  # This removes the custom pveproxy-ssl.pem/.key and restarts pveproxy, which then serves
  # the default node certificate again.
  host_exec "pvenode cert delete 1"
  note "pveproxy now serves the PVE node certificate (browser warning is back; that is expected)"
  note "leftovers, remove deliberately when the rollback is the final state:"
  note "  ssh tuns 'rm -rf $HDIR'   # the hypervisor key and CSR"
  note "  rm $CSR $LEAF $CHAIN"
}

"cmd_$cmd"
