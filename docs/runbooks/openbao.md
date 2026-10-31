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

## 2. Initialise (your terminal, once)

```sh
bao operator init -key-shares=3 -key-threshold=2
```

This prints three **unseal shares**, the threshold, and the **initial root token**. Store them
somewhere that is neither the Proxmox disk array (PBS copies it nightly, and a backup is useless
without the shares anyway) nor this repo. A password manager or paper in a safe works. Two shares
unseal the store; losing two shares loses everything in it, snapshots included.

## 3. Tell if it is sealed (and unseal after a reboot)

OpenBao starts sealed after every reboot on purpose (no auto-unseal, ADR 0014). Nothing is wrong;
the cluster keeps running on secrets already synced.

```sh
bao status                      # "Sealed: true" means it needs two shares
curl -s -o /dev/null -w '%{http_code}\n' $BAO_ADDR/v1/sys/health    # 503 while sealed
bao operator unseal              # paste a share, then a second, different one
```

## 4. Revoke the root token

Once audit logging, policies and the ESO role exist (steps below and the ADR), the root token has
no remaining job. Revoke it so it cannot leak out of your password manager:

```sh
bao token revoke -self           # with the root token in BAO_TOKEN
```

If root access is needed later, `bao operator generate-root` mints a new root token using unseal
shares, in your terminal, without a stored root token.

## 5. Enable the audit device

Do this while the root token still exists, before real secrets land:

```sh
bao audit enable file file_path=/var/log/openbao/audit.log
```

The log records every request (who did what to which path); values are HMAC-hashed, never stored
in clear. The directory is the only other path, besides the data directory, the service may write.

## 6. Raft snapshots

A snapshot is only useful together with the unseal shares, so it may live on the Mac:

```sh
mkdir -p ~/backups
bao operator raft snapshot save ~/backups/bao-$(date +%F).snap
```

Restore is a last resort: stop OpenBao, empty `/var/lib/openbao`, then
`bao operator raft snapshot restore <file>`, and start it again.

## Later (not this role)

- ESO on the cluster needs to reach `bao.home.arpa`: the 443 rule on sectools must then name the
  node IPs (ESO pods appear as node IPs after SNAT, ADR 0014). That firewall change belongs to
  the ESO step, not to this role.
