# Runbook: OpenBao on sectools (`bao.home.arpa`)

Why and what: [ADR 0014](../adr/0014-secrets-and-identity.md). OpenBao runs on `sectools` on
`127.0.0.1:8200` (Raft storage in `/var/lib/openbao`), behind Caddy TLS at `https://bao.home.arpa`.
The Ansible role never inits, unseals or stores any key or token. Everything below runs in your
terminal, and nothing it prints belongs in the repo, in a variable or in a log.

You need the `bao` CLI locally (`brew install openbao`) and the sectools Caddy root CA:
`ansible/files/ca/sectools-caddy-root.crt` (already fetched by the Caddy role).

```sh
export BAO_ADDR=https://bao.home.arpa
export BAO_CACERT=ansible/files/ca/sectools-caddy-root.crt
```

## 1. Deploy (once)

```bash
cd ansible
ansible-playbook playbooks/openbao.yml --limit sectools --check --diff
ansible-playbook playbooks/openbao.yml --limit sectools
ansible-playbook playbooks/dns.yml --limit gateway   # publishes bao.home.arpa
```

A restart seals the store (no auto-unseal, ADR 0014), so any later playbook run that changes the
config, unit or version leaves OpenBao sealed until you run step 3 again. Expect that; it is not
an outage the playbook caused silently.

The role also turns swap off on sectools: mlock is off, so a swapped-out page could otherwise
carry secrets to the disk PBS copies nightly. `swapon --show` should print nothing afterwards.

## 2. Initialise (your terminal, once)

```sh
bao operator init -key-shares=3 -key-threshold=2
```

This prints three **unseal shares**, the threshold, and the **initial root token**. Store them
somewhere that is neither the Proxmox disk array (PBS copies it nightly, and a backup is useless
without the shares anyway) nor this repo. A password manager or paper in a safe works. Two shares
unseal the store; losing two shares loses everything in it, snapshots included.

## 3. Tell if it is sealed (and unseal after a reboot)

OpenBao starts sealed after every reboot on purpose. Nothing is wrong; the cluster keeps running
on secrets already synced.

```sh
bao status                                            # "Sealed: true" means it needs two shares
curl -q -s -o /dev/null -w '%{http_code}\n' $BAO_ADDR/v1/sys/health
# 200 = unsealed, 501 = not initialised, 503 = sealed
bao operator unseal              # paste a share, then a second, different one
```

## 4. Audit log (comes with the deploy, verify here)

The audit device is declared in `openbao.hcl`, because OpenBao 2.7.2 refuses to enable audit
devices over the API (tested 2026-10-31). After init it logs every request and response with
HMAC-hashed values, never clear secrets:

```sh
bao audit list                   # shows file/
tail -1 /var/log/openbao/audit.log
```

`logrotate` moves the file weekly (`/etc/logrotate.d/openbao`, 8 kept) and sends SIGHUP, which
reopens the file without sealing the store. OpenBao fails closed: if the audit log cannot be
written, requests are denied, so a full disk here is an outage — monitoring covers disk space.

## 5. Raft snapshots

A snapshot is only useful together with the unseal shares, so it may live on the Mac:

```sh
mkdir -p ~/backups
bao operator raft snapshot save ~/backups/bao-$(date +%F).snap
```

Restore is a last resort. Unlike the old mental model, it does not touch the data directory by
hand: `restore` talks to the running, unsealed server and installs the snapshot into Raft. You
need a token that may restore (the root token, or a policy with `update` on
`sys/storage/raft/snapshot/restore`):

```sh
bao operator raft snapshot restore ~/backups/bao-2026-11-01.snap
# If the current cluster was re-initialised after the snapshot, the unseal keys no longer match
# the snapshot's data; -force skips that consistency check:
bao operator raft snapshot restore -force ~/backups/bao-2026-11-01.snap
```

After the restore, unseal with the shares that were current **when the snapshot was taken**: the
snapshot brings its own encrypted master key, so the shares from any later init stop working.

## 6. Revoke the root token (last)

Once the audit log is on, the ESO role and policies exist (ADR 0014 steps 3-4) and the proof has
passed, the root token has no remaining job. Revoke it so it cannot leak out of your password
manager:

```sh
bao token revoke -self           # with the root token in BAO_TOKEN
```

If root access is needed later, `bao operator generate-root` mints a new root token using unseal
shares, in your terminal, without a stored root token.

## ESO on the cluster (ADR 0014 step 3)

1. Platform repo (all in git, nothing hand-applied):
   - Argo app `external-secrets` (chart 2.14.0, one replica, ServerSideApply) installs ESO in namespace
     `external-secrets`; the CRDs come with the chart.
   - `cluster-config/eso-tokenreview.yaml` binds `system:auth-delegator` to ServiceAccount `dev/eso-belleshop`
     (the ServiceAccount itself lives in belleshop-deploy), so OpenBao verifies ESO's JWT through TokenReview
     with no stored reviewer token.
   - The 443 rule on sectools names the three k8s nodes: ESO pods appear as node IPs after SNAT. Caddy keeps
     `s3.home.arpa` admin-only (`allowed_clients` on the site), so the nodes reach the port but not the
     Terraform state.
2. OpenBao (your terminal; secrets stay out of the repo):
   ```sh
   scripts/openbao-setup-belleshop.sh   # kv-v2 at secret/, kubernetes auth, policy, role, secrets
   ```
   It skips what already exists, loads `private/belleshop-secrets.env` over stdin, and prints statuses, never
   values. `--overwrite` replaces the secrets only when you mean it.
3. belleshop-deploy: ServiceAccount `eso-belleshop`, `SecretStore` (carrying the sectools Caddy root CA) and an
   `ExternalSecret` for `secret/belleshop/app`. Step 3 ends when the synced Secret equals today's
   `belleshop-secrets` and nothing changed for the app.
