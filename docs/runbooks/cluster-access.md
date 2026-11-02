# Runbook: scoped cluster access with short-lived certificates

Why: [ADR 0014](../adr/0014-secrets-and-identity.md) decision 9 / rollout step 8.
Daily access from the Mac is a client certificate that lasts hours, in groups
`belleshop-operators` (namespace `dev`) and `platform-viewers` (cluster status).
The `kubeadm:cluster-admins` kubeconfig lives only on the control-plane node.

This Role is **not** a Secret boundary inside `dev`: `pods/exec` reads mounted
files and env, and `patch` on Rollouts (required to promote) can change a pod
template. Argo CD self-heal undoes a template change only after it has run.
It **is** a boundary for every other namespace and for cluster-scoped Secrets.

## Issue (or renew) a daily certificate

The private key is generated on the Mac and stays under `private/k8s-access/`
(gitignored, 0600). Approval uses `/etc/kubernetes/admin.conf` on `Master` over
SSH. This never writes `~/.kube/config`. Only groups `belleshop-operators` and
`platform-viewers` are accepted.

```sh
cd ~/homelab-platform   # or the worktree
scripts/k8s-issue-access-cert.sh <username>
export KUBECONFIG="$PWD/private/k8s-access/<username>.kubeconfig"
kubectl auth can-i get pods -n dev
kubectl auth can-i get secrets -n dev    # expect no
```

Renewing is running the same command again. The script reuses the key. The
signer may issue a lifetime shorter than the requested 8h; the script prints
only `notAfter=...` from the issued certificate. Requested: 28800s. Observed on
this cluster 2026-11-01: issued lifetime was 8 hours (`notAfter` ~28800s later).

Undo: `rm -P private/k8s-access/<username>.key private/k8s-access/<username>.kubeconfig`.
That does not revoke an already-issued certificate.

## What the groups can do

`belleshop-operators` (Role in `dev`): read most objects, logs, restart a pod
with delete, promote a Rollout (`patch` on `rollouts` and `rollouts/status`;
that is what `kubectl argo rollouts promote` uses). `pods/exec` is allowed so
MySQL/backend debugging and `scripts/openbao-setup-mysql-rotation.sh` can run
without admin. There is no `patch`/`update` on Deployments or StatefulSets.

`platform-viewers` (ClusterRole): nodes, namespaces, pods, events, Argo CD
Applications, Rollouts, ExternalSecret status, Gateway API — no Secrets. The
ADR preferred per-namespace Roles; this ClusterRole exists because nodes and
"is Argo synced" are not properties of `dev`.

## Moving the admin credentials off the Mac

Do this only after:

1. etcd encryption rewrite (`scripts/k8s-rewrite-secrets.sh` on the
   `etcd-encryption` work) has finished — that script **get**s and **replace**s
   Secrets, so it needs admin. This cutover is after that, not before.
2. The limited kubeconfig can list pods in `dev` and is denied Secrets.

Admin when you need it:

```sh
ssh Master
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes
```

`~/.kube/config` holds **several** contexts. Renaming the whole file would drop
the others and still leave the admin key on disk as a `.bak`. There is also a
second file, `~/.kube/config-homelab`, that is only this cluster's kubeadm
admin user (`kubernetes-admin`, client certificate).

Copy, then remove **only** this cluster's admin entries. Delete the copies once
a day of limited-cert work has succeeded. Time Machine (and any other backup)
may still hold older copies of these files until those snapshots expire.

```sh
umask 077
cp ~/.kube/config ~/.kube/config.bak-before-cutover
cp ~/.kube/config-homelab ~/.kube/config-homelab.bak-before-cutover

# ~/.kube/config: drop only the homelab admin context/user/cluster.
# Other contexts stay. The homelab cluster name in this file is `kubernetes`
# and the user is `kubernetes-admin`.
# First, unset the current context: the removed context was the current one, so after
# removal a plain `kubectl` must select nothing rather than silently target a wrong cluster.
kubectl config unset current-context --kubeconfig ~/.kube/config
kubectl config unset contexts.homelab-cluster --kubeconfig ~/.kube/config
kubectl config unset users.kubernetes-admin --kubeconfig ~/.kube/config
kubectl config unset clusters.kubernetes --kubeconfig ~/.kube/config

# Dedicated kubeadm copy: the whole file is this cluster.
rm ~/.kube/config-homelab

# After limited access is confirmed:
rm -P ~/.kube/config.bak-before-cutover ~/.kube/config-homelab.bak-before-cutover
```

Point `KUBECONFIG` at `private/k8s-access/<username>.kubeconfig` for daily use
(or merge that as a new non-admin user/context). Do not put the admin user back
into `~/.kube/config`.

### What still used the Mac admin kubeconfig

**Cutover done 2026-11-02.** The limited certificate carries the daily path, only this
cluster's admin entries were removed from `~/.kube/config`, `~/.kube/config-homelab` is
deleted, and the `.bak` copies were deleted after a day of work with the limited
certificate. Admin is the SSH path above (`ssh Master`, `/etc/kubernetes/admin.conf`).

Observed with the real limited certificate (issued 2026-11-01/02, 8h lifetime, groups
`belleshop-operators` + `platform-viewers`). Note `kubectl auth can-i` needs
`--subresource=exec` for the exec check, or it answers about pods generally:

```sh
export KUBECONFIG="$PWD/private/k8s-access/<username>.kubeconfig"
kubectl auth can-i get pods -n dev                          # yes (real run: 5 pods)
kubectl auth can-i create pods -n dev --subresource=exec    # yes
kubectl auth can-i patch rollouts -n dev                    # yes
kubectl auth can-i get nodes                                # yes
kubectl auth can-i get secrets -n dev                       # no
kubectl auth can-i create pods -n dev                       # no
kubectl auth can-i patch deployments -n dev                 # no
kubectl auth can-i list secrets -n kube-system              # no
kubectl auth can-i delete pods -n kube-system               # no
```

| Consumer | After cutover |
|---|---|
| Daily `kubectl` in `dev` / `kubectl argo rollouts promote` | Limited kubeconfig (verified with the real certificate: `patch` on `rollouts` is allowed) |
| `scripts/openbao-setup-mysql-rotation.sh` (`pods/exec` on `mysql-0`; DB password from `private/belleshop-secrets.env`) | Limited kubeconfig (verified with the real certificate: `create pods/exec` in `dev` is allowed) |
| `scripts/openbao-setup-belleshop.sh` (`kubectl -n kube-public get configmap kube-root-ca.crt`) | **Admin path.** `system:authenticated` cannot read that ConfigMap (observed `can-i`: no) |
| `scripts/k8s-rewrite-secrets.sh` (get + replace every Secret) | **Admin path.** It finished before the cutover (2026-11-01/02); re-running it means the admin SSH path |
| Ansible drain/upgrade | `kubectl` **on the nodes**, not the Mac file |
| Terraform | Proxmox API only; no kubeconfig |
| Argo CD repo credential / `grafana-admin` restore | **Admin path** (`ssh Master`) |
| CI (Jenkins) | Unconfirmed whether it holds a copied `admin.conf`; carried over (ROADMAP, Week 5) |

## The existing admin certificate is not revoked by deleting the file

The Mac's current client certificate `notAfter` is **Aug 17 12:22:41 2027 GMT**
(`openssl x509 -noout -enddate` on the client cert only). kubeadm will keep
honouring it until then.

Removing the user from the kubeconfig files only removes **those copies of the
key**. Time Machine, a copied `config-homelab`, or anything that already copied
the PEM can still authenticate as `kubeadm:cluster-admins`.

What actually invalidates it sooner:

| Action | Cost |
|---|---|
| Wait until 2027-08-17 | None. Combined with deleting the Mac copies, this is enough if the key did not leak |
| Rotate the **cluster CA** | Cluster-wide outage and a new trust bundle everywhere. This is the only real revocation |

Recommend: remove the Mac admin user/files after the limited cert works; keep
admin.conf only on `Master`; rotate the cluster CA **only if** that admin key
leaked.

## Checks

```sh
kubectl --kubeconfig private/k8s-access/<username>.kubeconfig auth can-i --list -n dev
kubectl --kubeconfig private/k8s-access/<username>.kubeconfig auth can-i get secrets --all-namespaces
kubectl --kubeconfig private/k8s-access/<username>.kubeconfig -n kube-system get pods   # viewer: yes; mutate: no
```
