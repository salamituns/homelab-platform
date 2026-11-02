# ADR 0014: Secrets and identity with OpenBao, External Secrets Operator and scoped cluster access

- Status: Accepted (owner, 2026-10-31); rollout complete 2026-11-02.
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
5. **Give OpenBao a dedicated MySQL account with global `CREATE USER`** (tested on 8.0.46, 2026-10-31): MySQL cannot scope
   an account to changing only the app user, so it can create users and change any ordinary user's password, but not
   `root`, which holds `SYSTEM_USER`. `APPLICATION_PASSWORD_ADMIN` is not needed. Accepted because OpenBao already holds
   the app's password, so the account adds little data access, though it could disrupt ordinary users. `root@'%'` is
   still removed.
6. **Reach MySQL through a dedicated MetalLB address** (`.244`) with `loadBalancerSourceRanges` limited to `sectools`.
   The account uses `REQUIRE SSL` and OpenBao connects with `tls=skip-verify`: the link is encrypted, but the server is
   not authenticated, because MySQL's auto-generated certificate has no usable SAN. Week 6's cert-manager replaces it
   with a verified certificate. Two additions from the step 4 spike (2026-10-31): the Service also sets
   `allocateLoadBalancerNodePorts: false`, because a NodePort is open to any source and bypasses the range; and the
   account is `bao-admin@'10.244.%'`, because kube-proxy masquerades LoadBalancer traffic to the receiving node's
   own address in its Flannel pod subnet (the CNI is kube-flannel-ds; MySQL sees `10.244.x.y`, never the
   `192.168.1.x` client IP). `rotate-root` works on OpenBao 2.7.2 and REQUIRE SSL survives it, but
   `root_rotation_statements` are needed: the plugin default targets `'{{username}}'@'%'`, which fails with MySQL
   error 1396 on a host-scoped account.
7. **Have the app read the password from a mounted file** on each new connection, so it needs no restart. Use MySQL's
   `RETAIN CURRENT PASSWORD` so the old and new passwords both work during the switch (confirmed on 8.0.46, 2026-10-31:
   after a rotation both log in, and the older one stops working at the next rotation). Creating the static role
   rotates the app password immediately (verified on OpenBao 2.7.2) and starts the rotation clock, so the setup
   script creates the role only behind an explicit `--create-static-role` flag, after the app already reads the
   optional file mount (the volume is `optional: true`, so pods start before the Secret exists and kubelet delivers
   the file into running pods once it does, verified on the cluster 2026-10-31).
8. **Enable etcd encryption at rest** with an `EncryptionConfiguration` (secretbox, the docs' Strong
   and Faster provider; aescbc is rated Weak), then rewrite existing Secrets. ESO copies
   secrets into etcd, so this belongs in the same week.
9. **Scope cluster access.** Create per-namespace Roles for day-to-day mutate (starting with `dev`), a
   ClusterRole only for cluster-wide status (nodes, Argo Applications), issue short-lived client
   certificates through the `CertificateSigningRequest` API, and keep the admin kubeconfig on the
   control-plane node only.

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
- A LoadBalancer Service with `loadBalancerSourceRanges` still opens a NodePort for every source by default;
  `mysql-bao` disables node ports for that reason (checked on the cluster, 2026-10-31). Any later LoadBalancer that
  must stay source-limited needs the same field.
- The `bao-admin` account is scoped to `10.244.%`, not `192.168.1.%`: kube-proxy masquerades LoadBalancer traffic
  to the receiving node's address in its Flannel pod subnet, so a LAN-side host scope would never match.
- Creating the static role is a one-way door on a 24h timer: the old password (still held by running pods and the
  hand-made `belleshop-secrets`) dies at the next rotation, and a pod restart does not help while the app reads
  the environment variable. The role is therefore created only after the app reads the optional file mount.
- `sectools` becomes more important, and losing it stops rotation and new secrets. Running apps keep working from their
  synced Kubernetes Secrets.
- OpenBao's VM backup is encrypted but useless without the unseal shares. This makes the deferred off-host copy of PBS
  ([ADR 0006](0006-backups-proxmox-backup-server.md)) more valuable.
- ESO pods reach `sectools` from node IPs after SNAT, so the firewall rule names the nodes rather than a pod range.
- The `SecretStore` must carry the `sectools` Caddy root CA, because the lab CA is not public.
- `sectools` runs without swap: mlock is off with Raft, and a swapped-out page could otherwise carry secrets to the disk
  PBS copies nightly.
- Audit devices are declared in OpenBao's config file; 2.7.2 refuses to create them through the API.
- etcd Secrets are encrypted with a key that lives on the master, and PBS backs the master VM up
  nightly, so until the PBS client-side encryption decision (`TODO(encryption)` in the backups
  runbook) is made, the PBS copies hold both the key and the encrypted data. The runbook keeps the
  off-host copy of the key in the password manager as the real custody move.
- Encrypting new writes does not erase old copies: plaintext Secret revisions stay in etcd until
  compaction and a `defrag`, the pre-enable snapshot is plaintext, and PBS backups of the master
  taken before the change keep plaintext until the 7/4/3 retention prunes them (about three
  months). Of the stored values only the database password ages out on its own (24h rotation); the
  MySQL root password, `SECRET_KEY` and pull credentials stay valid until rotated by hand.
- While MySQL is unreachable, OpenBao keeps serving the current password and retries in the background; in the test it
  rotated about 8 seconds after MySQL came back.
- The app gains a dependency on a mounted file. Local `docker compose` keeps using environment variables, so the code has
  to support both.

## Rollout plan

Each step is separately reversible.

1. **Done 2026-10-31 (throwaway database: OpenBao 2.7.2 against MySQL 8.0.46):** `RETAIN CURRENT PASSWORD` works, the
   dual-password window is one rotation, and no app fallback is needed. The least privilege the rotation needs is global
   `CREATE USER` (decision 5). ESO's Vault provider is checked in step 3 instead: a local dev server is not reachable
   from the cluster.
2. **Done 2026-10-31:** OpenBao on `sectools`. Ansible role, dry run first. The owner initialised
   it and stored the shares.
3. **Done 2026-11-01:** ESO on the cluster. What exists is the shadow Secret
   `belleshop-secrets-eso`, synced from OpenBao, which no workload reads. Only the app's
   database password moved: workloads still read the MySQL root password, user, database name
   and `SECRET_KEY` from the hand-made `belleshop-secrets`. In git: the Argo app with chart
   values, the TokenReview binding (cluster-config), the sectools firewall and Caddy rules,
   the setup script; the ServiceAccount, `SecretStore` and `ExternalSecret` in
   `belleshop-deploy`.
4. **Done 2026-11-01:** dedicated MySQL account and the `.244` path. In git: the `mysql-bao` Service
   (sectools-only, no NodePort) and the ESO objects for the shadow Secret `belleshop-db-eso` in belleshop-deploy, and
   `scripts/openbao-setup-mysql-rotation.sh` here (account, connection, root rotation, policy path; the static role
   only behind `--create-static-role`, so the 24h clock starts only once the app reads the optional file mount).
   Tested end to end on a dev OpenBao 2.7.2 against a throwaway MySQL behind a `.245` LoadBalancer: creation,
   takeover, idempotent re-run, immediate rotation on static-role creation, the one-rotation dual-password window,
   reads not rotating, and the negative test (a non-allowed host refused at the LB address but connected through the
   NodePort until node ports were disabled). The owner ran both phases against the real store; `root'@'%'` was
   dropped (only `root@localhost` remains), and a manual rotation afterwards succeeded (MySQL
   `password_last_changed` moved, `bao-admin` unchanged).
5. **Done 2026-11-01:** BelleShop reads the password from the mounted file on each connection
   (`get_db_password()`, BelleShop PRs #14 and #15); the env var was removed from the Rollout
   afterwards (belleshop-deploy #19).
6. **Done 2026-11-01:** the proof. Rotate in OpenBao and keep a traffic probe running: 457/457 DB-backed logins
   during rotation, 0 restarts, no git change. A manual rotation afterwards also succeeded, with the file in both
   backend pods matching the Secret by hash and 10/10 DB-backed login probes.
7. **Done 2026-11-01/02:** etcd encryption at rest, following a backup of etcd. In git: the
   playbook (etcd snapshot first, verified; secretbox key generated on the master only, `no_log`,
   never overwritten; flags in both the kube-apiserver manifest and the kubeadm
   ClusterConfiguration so `k8s-upgrade.yml` regenerates them), the Secrets rewrite script, and
   the runbook. The manifest is patched with ONE atomic write: kubelet starts a pod for anything
   in `/etc/kubernetes/manifests`, so the flag, its mount and its volume must never arrive one
   by one. The success wait checks the mirror pod `kube-apiserver-<node>` carries the flag and
   is Ready, because `/readyz` alone answers 200 from the old server. The provider is secretbox:
   the Kubernetes docs rate it Strong and Faster, while
   aescbc is rated Weak (padding-oracle). What proved different while building it: kubeadm
   v1beta4 takes `apiServer.extraArgs` as a **list** of `{name, value}` pairs (the map form most
   examples still show fails `kubeadm config validate` on 1.33.13), etcdctl only exists inside
   the etcd image (crictl is not installed on the master), so the snapshot goes through
   `kubectl exec` into the etcd static pod, and v1.33.13 supports
   `--encryption-provider-config-automatic-reload`, so key rotation needs no API server restart.
   The atomic manifest change was tested against a fetched copy of the real kube-apiserver.yaml
   (check mode writes nothing, apply once, idempotent re-run, simulated kubeadm regeneration),
   the ConfigMap transform passed
   `kubeadm config validate` on the master and a server dry run of the patch, and the rewrite
   script refuses to run while the live API server does not carry the flag. Applied on the
   cluster 2026-11-01/02: 34 Secrets rewritten (0 failed), 34/34 read back from etcd with the
   `k8s:enc:secretbox:v1:key1:` prefix, a newly created Secret stored encrypted and still
   served, the plaintext Secret count in the raw db file 35 shortly after the rewrite, 7 before
   the defrag and 0 after it (DB 35.6 MB -> 14.1 MB), and the pre-enable snapshot deleted after
   that.
8. **Done 2026-11-02:** cluster access. In git: Role `belleshop-operator` in `dev` (no Secret
   get/list/watch; no patch on Deployments/StatefulSets; `pods/exec` and Rollout `patch` mean this is
   **not** a Secret boundary inside `dev`, only outside it), ClusterRole `platform-viewer` for
   cluster-wide status, bindings to groups `belleshop-operators` / `platform-viewers`, and
   `scripts/k8s-issue-access-cert.sh` (allowlist of those two groups only). The Mac admin client
   certificate `notAfter` is 2027-08-17; removing files does not revoke it. The cutover ran after the
   etcd-encryption Secret rewrite: the owner issued a real limited certificate (8h, both groups),
   the allow/deny matrix held (get pods, pods/exec and patch rollouts in `dev`, get nodes: yes;
   get secrets in `dev`, create pods, patch deployments, list secrets in `kube-system`,
   delete pods in `kube-system`: no; `get pods -n dev` returned 5 pods), then removed only this
   cluster's admin entries from `~/.kube/config` and deleted `~/.kube/config-homelab`; the
   `.bak` copies are kept for a day of limited-cert work and then deleted, and they still hold
   the admin key until then; the admin path over SSH
   (`/etc/kubernetes/admin.conf` on the control-plane node) was confirmed working.

## References

- [OpenBao database secrets engine](https://openbao.org/docs/secrets/databases/) and [MySQL/MariaDB plugin](https://openbao.org/docs/secrets/databases/mysql-maria/)
- [OpenBao database API](https://openbao.org/docs/api/secret/databases/)
- [Using ESO with OpenBao (Stakater)](https://docs.stakater.com/reloader/latest/integrations/openbao/openbao-eso.html), a third-party guide. Step 1 checks it against this lab.
