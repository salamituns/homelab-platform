# Runbook: Proxmox UI certificate from the lab CA (ADR 0015 section B, step 2)

The pveproxy web UI on `tuns` (`:8006`) serves the PVE node certificate, signed by PVE's own
cluster CA, which no client trusts. This runbook puts a lab-CA leaf there instead:
`proxmox.home.arpa` / `tuns.home.arpa` (both resolve to `192.168.1.181`), 825 days (Apple's maximum for TLS server
certificates, enforced even for a user-trusted CA; a 1095-day leaf failed with `CSSMERR_TP_CERT_SUSPENDED`). The private
key is generated ON `tuns` and never leaves it; only the CSR comes to the Mac and only the
public chain goes back. ACME was ruled out in the ADR: `home.arpa` is not publicly resolvable,
so http-01/dns-01 cannot validate.

**Implementation note 2026-11-02 (deliberate deviation from the ADR):** the leaf is signed by
the lab **intermediate**, not the offline root, so the root key stays untouched after CA
creation. Clients verify the same chain (root -> intermediate -> leaf, both name-constrained
to `home.arpa`); if the intermediate is ever reissued, re-sign this leaf at the same time.

Everything runs from `~/homelab-platform` on the Mac. `ssh tuns` is key-only root
(`docs/runbooks/proxmox.md`). One command per line; `export OPENSSL_BIN` first, because the
Mac default `openssl` is LibreSSL and the script refuses it:

```sh
export OPENSSL_BIN=/opt/homebrew/opt/openssl@3/bin/openssl
```

## 1. csr: key and CSR on `tuns` (the key never leaves the hypervisor)

```sh
./scripts/pve-ui-cert.sh csr --dry-run
./scripts/pve-ui-cert.sh csr
```

What it does: `umask 077`, then an ECDSA P-256 key and a CSR at `/root/pve-ui-cert/` on
`tuns` (refuses to overwrite an existing key), and copies back ONLY the CSR to
`private/pve-ui/tuns.csr` (gitignored, like all of `private/`).

## 2. sign: leaf and chain on the Mac, strictly verified

```sh
./scripts/pve-ui-cert.sh sign
```

Signs with the intermediate: 825 days, `subjectAltName` `DNS:proxmox.home.arpa`,
`DNS:tuns.home.arpa`, `IP:192.168.1.181`, EKU `serverAuth`, `keyUsage` `digitalSignature`,
`basicConstraints CA:false`. The script sets all of these itself: the CSR subject must be
`CN=proxmox.home.arpa` and nothing from the CSR's extensions is copied. The `IP` SAN sits
outside the DNS-only `home.arpa` name constraint, which is allowed (RFC 5280 name constraints
apply per name form, and no IP subtree is listed); the strict verify plus the real handshake
in the test harness prove it. Outputs: `private/pve-ui/tuns.crt` and
`private/pve-ui/tuns-chain.pem` (leaf + intermediate). If
`openssl verify -x509_strict` against the root fails, the step keeps nothing.

Record the dates now (renewal section below):

- Issued: 2026-11-02 (installed and verified: macOS trust "verification successful", both names 200)
- Expires (notAfter printed by the sign step): 2029-02-04
- Renewal reminder (24 months after issue): 2028-11-02

## 3. install: chain to `tuns`, pvenode, verify

```sh
./scripts/pve-ui-cert.sh install --dry-run
./scripts/pve-ui-cert.sh install
```

The steps it performs (PVE 9.1.2 syntax, verified against `pvenode(1)` and the PVE source on
`tuns`):

1. copy `private/pve-ui/tuns-chain.pem` to `tuns:/root/pve-ui-cert/pveproxy-ssl-chain.pem`;
2. pre-stage the key: `cat /root/pve-ui-cert/pveproxy-ssl.key > /etc/pve/local/pveproxy-ssl.key`
   (pmxcfs gives it 0640 root:www-data itself and may refuse chmod/chown), so `pvenode` never receives the key as an argument (PVE
   accepts `cert set` without the key argument when the key file already exists);
3. `pvenode cert set /root/pve-ui-cert/pveproxy-ssl-chain.pem --force 1 --restart 1` (pvenode takes
   file paths and reads them itself; the first run passed the PEM text and failed here, key staged, no cert set)
   (the chain, not the key, is the argument; `pvenode cert delete` takes restart as a
   positional `1` instead, see rollback);
4. curl both names against the vendored root and show the issuer via `s_client`.

Checks from the Mac afterwards (the script runs these too; expect `200`-ish codes and
`Verify return code: 0 (ok)` with the lab intermediate as issuer):

```sh
curl -q --cacert ansible/files/ca/lab-root.crt -o /dev/null -w '%{http_code}\n' https://proxmox.home.arpa:8006/
curl -q --cacert ansible/files/ca/lab-root.crt --resolve tuns.home.arpa:8006:192.168.1.181 -o /dev/null -w '%{http_code}\n' https://tuns.home.arpa:8006/
$OPENSSL_BIN s_client -connect 192.168.1.181:8006 -servername proxmox.home.arpa -CAfile ansible/files/ca/lab-root.crt </dev/null
```

Browser: open `https://proxmox.home.arpa:8006/` — no warning once the root is in the system
store (`docs/runbooks/internal-ca.md` section 4). TOTP login is unaffected
(`docs/runbooks/proxmox.md` section 2).

If install fails midway (key staged, no cert set): pveproxy keeps serving the default node
certificate; the script always passes `--force`, so simply fix and rerun `install`. To clean
the staged key by hand: `ssh tuns 'rm /etc/pve/local/pveproxy-ssl.key'`.

## 4. Rollback

```sh
./scripts/pve-ui-cert.sh rollback
```

That runs `ssh tuns 'pvenode cert delete 1'`: removes the custom `pveproxy-ssl.pem`/`.key`
and restarts pveproxy, which then serves the default node certificate again (the browser
warning returns; that is expected). Leftovers, only if the rollback is the final state:

```sh
ssh tuns 'rm -rf /root/pve-ui-cert'
rm private/pve-ui/tuns.csr private/pve-ui/tuns.crt private/pve-ui/tuns-chain.pem
```

## 5. Renewal (30-month reminder recorded in section 2)

Reissue WITHOUT a new key (the key on `tuns` is reused); the script never overwrites the old
leaf, so move it aside first:

```sh
mv private/pve-ui/tuns.crt private/pve-ui/tuns.crt.old-$(date +%F)
mv private/pve-ui/tuns-chain.pem private/pve-ui/tuns-chain.pem.old-$(date +%F)
./scripts/pve-ui-cert.sh sign
./scripts/pve-ui-cert.sh install
```

Record the new dates in section 2 and delete the `.old-*` files once the new certificate
checks out.

## 6. Test harness (never touches `tuns` or `private/ca`)

```sh
./scripts/pve-ui-cert-test.sh
```

Runs `csr` + `sign` for real against a throwaway name-constrained CA in a temp dir, strict
verifies the leaf, checks the SANs, EKU, keyUsage, the chain file and the key custody (mode
600, never copied back), and does a real `openssl s_server` + `curl --cacert` handshake for
both names. Run it after any change to `scripts/pve-ui-cert.sh`.
