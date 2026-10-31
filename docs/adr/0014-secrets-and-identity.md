# ADR 0014: Secrets and identity with OpenBao, External Secrets Operator and scoped cluster access

- Status: Proposed. Owner accepted the main choices on 2026-10-31; the MySQL network path below is new and still needs review.
- Date: 2026-10-31

## Context

Week 5 of the [ROADMAP](../../ROADMAP.md) asks for a secret store, BelleShop's database credentials managed from it,
and no cluster-admin kubeconfigs on laptops. The proof: rotate the database password in the store and the app picks it
up with no git change.

What we found on 2026-10-31:

| Area | Current state | Why it matters |
|---|---|---|
| App secret | `dev/belleshop-secrets` is created by hand. It has no source of truth other than `private/` on the Mac | Rotation is manual, and nothing records who changed what |
| MySQL | Runs in-cluster behind a ClusterIP Service. The app has its own DML-only user since 2026-10-31 | Whatever rotates the password must be able to reach MySQL |
| App config | The backend reads the password from an environment variable, and opens a new connection per request | An environment variable is fixed at process start, so a running pod never sees a new value |
| Other cluster secrets | `grafana-admin`, `nexus-pull` and the Argo CD Gitea credentials are also hand-made | They can follow once the path is proven |
| Laptop access | The kubeconfig is a `kubeadm:cluster-admins` client certificate | Kubernetes cannot revoke a client certificate before it expires |
| Storage | `local-path` only, so a volume is tied to one node | An in-cluster store would stop if that node stopped |

Changing a value in a secret store does not change a password in MySQL, so the proof needs three separate steps:
**change it in MySQL, deliver it to the pod, and have the running app read it.**

## Options considered

### Secret store

| Option | For | Against |
|---|---|---|
| **OpenBao** (chosen) | Open source (MPL-2.0), Linux Foundation project, Vault-compatible API, current release v2.7.2 | Smaller ecosystem than Vault |
| HashiCorp Vault | The name most job listings use | BUSL licence. This lab already moved off MinIO for similar project-direction reasons ([ADR 0007](0007-terraform-state-seaweedfs-s3.md)) |
| SOPS or Sealed Secrets | No server to run | Secrets stay in git and rotation still needs a commit, which fails the proof |

### Where it runs

| Option | For | Against |
|---|---|---|
| **`sectools` VM** (chosen) | Survives a cluster rebuild and the Week 8 node-loss drill. No unseal material in the cluster. About 3.2 GB of memory and 49 GB of disk free | Must reach MySQL from outside the cluster. Shares a VM with the Terraform state store, so a compromise of `sectools` exposes both |
| On the cluster (the ROADMAP's wording) | Direct network path to MySQL. Standard Helm chart | Tied to one node by `local-path`. Auto-unseal would keep its key on the cluster it protects |
| A new VM | Isolates it from the state store | Another VM to run for one service. Worth revisiting if the store gets more clients |

## Decision

1. **Run OpenBao on `sectools`** as a systemd service managed by a new Ansible role, using integrated (Raft) storage on
   one node. TLS comes through the existing Caddy pattern at `bao.home.arpa`.
2. **Unseal by hand for now.** Use three key shares with a threshold of two. The shares and the initial root token are
   generated in the owner's terminal, are never seen by an agent, and are not stored on the disk array that OpenBao backs
   up to. Revoke the root token once setup is done.
3. **Install External Secrets Operator (ESO) on the cluster** through Argo CD, using its Vault provider with
   Kubernetes auth. Each namespace gets its own `SecretStore` and an OpenBao role limited to its own path.
4. **Use a static database role** for the app user. Dynamic per-pod users can come later.
5. **Give OpenBao a dedicated MySQL admin account** that can only change the app user's password, and then remove
   `root@'%'`.
6. **Reach MySQL through a dedicated MetalLB address** (`.244`) with `loadBalancerSourceRanges` limited to `sectools`.
7. **Have the app read the password from a mounted file** on each new connection, so it needs no restart. Use MySQL's
   `RETAIN CURRENT PASSWORD` so the old and new passwords both work during the switch.
8. **Enable etcd encryption at rest** with an `EncryptionConfiguration`, then rewrite existing Secrets. ESO copies
   secrets into etcd, so this belongs in the same week.
9. **Scope cluster access.** Create per-namespace Roles, issue short-lived client certificates through the
   `CertificateSigningRequest` API, and keep the admin kubeconfig on the control-plane node only.

## How rotation works

```text
OpenBao static role --ALTER USER ... RETAIN CURRENT PASSWORD--> MySQL (.244, sectools only)
        |
        | ESO polls, on its refreshInterval
        v
Kubernetes Secret --kubelet syncs the volume--> file in the backend pod --read on each connection--> MySQL
```

The refresh interval and the kubelet sync together must be well under the rotation period. The old password stays valid
only until the next rotation, so a pod that has missed one full period starts to fail.

## Not now

- **Auto-unseal.** It needs a KMS or a key stored somewhere safe. After a reboot, the cluster keeps running on the Secrets
  ESO already synced, so a hand unseal is acceptable while an alert covers the sealed state.
- **High availability.** Raft needs three nodes for it. One node plus snapshots suits this lab.
- **OIDC login to the cluster.** This is the better long-term answer, but short-lived certificates teach the same point
  with fewer parts.
- **Moving every secret.** Jenkins credentials and the files in `private/` come after the proof passes.

## Consequences

- MySQL gets a LAN address for the first time. The source-range limit is the main control until the default-deny
  NetworkPolicies arrive in Week 6, so the rollout has to test it from a host that is not allowed.
- `sectools` becomes more important, and losing it stops rotation and new secrets. Running apps keep working from their
  synced Kubernetes Secrets.
- OpenBao's VM backup is encrypted but useless without the unseal shares. This makes the deferred off-host copy of PBS
  ([ADR 0006](0006-backups-proxmox-backup-server.md)) more valuable.
- ESO pods reach `sectools` from node IPs after SNAT, so the firewall rule names the nodes rather than a pod range.
- The `SecretStore` must carry the `sectools` Caddy root CA, because the lab CA is not public.
- The app gains a dependency on a mounted file. Local `docker compose` keeps using environment variables, so the code has
  to support both.

## Rollout plan

Each step is separately reversible.

1. **Test the unverified parts on a throwaway database:** the static role's `rotation_statements` with `RETAIN CURRENT
   PASSWORD`, and ESO's Vault provider against OpenBao. If `RETAIN` doesn't work, fall back to a short retry in the app.
2. **OpenBao on `sectools`:** Ansible role, dry run first. The owner initialises it and stores the shares.
3. **ESO on the cluster,** then sync `belleshop-secrets` from OpenBao with the current values. Nothing should change for
   the app at this point.
4. **Dedicated MySQL account and the `.244` path,** with a negative test from a host outside the source range.
5. **App change:** the owner writes the `get_db()` file read and the retry behaviour.
6. **The proof:** rotate in OpenBao and keep a traffic probe running. Show the new password in use, no git change, and no
   failed requests.
7. **etcd encryption at rest,** following a backup of etcd.
8. **Cluster access:** Roles and short-lived certificates, then move the admin kubeconfig off the Mac.
   This runs last because every earlier step uses that access.

## References

- [OpenBao database secrets engine](https://openbao.org/docs/secrets/databases/) and [MySQL/MariaDB plugin](https://openbao.org/docs/secrets/databases/mysql-maria/)
- [OpenBao database API](https://openbao.org/docs/api/secret/databases/)
- [Using ESO with OpenBao (Stakater)](https://docs.stakater.com/reloader/latest/integrations/openbao/openbao-eso.html), a third-party guide. Step 1 checks it against this lab.
