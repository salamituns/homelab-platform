# Runbook: scoped cluster access with short-lived certificates

Why: [ADR 0014](../adr/0014-secrets-and-identity.md) decision 9 / rollout step 8.
Daily access from the Mac is a client certificate that lasts hours, in groups
`belleshop-operators` (namespace `dev`) and `platform-viewers` (cluster status).
The `kubeadm:cluster-admins` kubeconfig lives only on the control-plane node.

## Issue (or renew) a daily certificate

The private key is generated on the Mac and stays under `private/k8s-access/`
(gitignored, 0600). Approval uses `/etc/kubernetes/admin.conf` on `Master` over
SSH. This never writes `~/.kube/config`.

```sh
cd ~/homelab-platform   # or the worktree
scripts/k8s-issue-access-cert.sh <username>
# optional extra groups after the username; system:masters and kubeadm:cluster-admins are refused
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

`belleshop-operators` (Role in `dev`): read most objects, logs, restart pods
(delete) and patch Rollouts/Deployments/StatefulSets (promote / restart).
`pods/exec` is allowed so MySQL/backend debugging and
`scripts/openbao-setup-mysql-rotation.sh` work without admin. Exec can read
files already mounted from Secrets; Secret `get/list/watch` and pod **create**
are denied so you cannot dump etcd Secrets or mount an arbitrary one.

`platform-viewers` (ClusterRole): nodes, namespaces, pods, events, Argo CD
Applications, Rollouts, ExternalSecret status, Gateway API — no Secrets. The
ADR preferred per-namespace Roles; this ClusterRole exists because nodes and
"is Argo synced" are not properties of `dev`.

## Moving the admin kubeconfig off the Mac

Do this only after the limited kubeconfig can list pods in `dev` and is denied
Secrets.

Admin when you need it:

```sh
ssh Master
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes
```

On the Mac, rename rather than shred until the next day of work succeeds:

```sh
mv ~/.kube/config ~/.kube/config.cluster-admins.bak
chmod 600 ~/.kube/config.cluster-admins.bak
# after a few days: rm -P ~/.kube/config.cluster-admins.bak
```

### What still used the Mac admin kubeconfig

| Consumer | After cutover |
|---|---|
| Daily `kubectl` / Argo Rollouts promote in `dev` | Limited kubeconfig |
| `scripts/openbao-setup-mysql-rotation.sh` (`pods/exec` on `mysql-0`; root password from `private/belleshop-secrets.env`, not the Secret API) | Limited kubeconfig (`belleshop-operators`) |
| `scripts/openbao-setup-belleshop.sh` (reads `kube-public/kube-root-ca.crt`) | Limited kubeconfig (`system:authenticated` can read that ConfigMap on kubeadm) |
| Ansible (`ansible/playbooks/k8s-upgrade.yml`, kubelet drain) | Runs `kubectl` **on the nodes**, which already have admin. Not the Mac file |
| Terraform | Proxmox API only; no kubeconfig |
| Argo CD repo credential / `grafana-admin` restore (`docs/runbooks/argocd-platform.md`) | **Admin path** (`ssh Master` then kubectl). Limited cert cannot get Secrets |
| CI (Jenkins) | Its own credentials, not the Mac kubeconfig. Confirm nothing in Jenkins still points at a copied admin.conf |

## The existing admin certificate is not revoked by deleting the file

The Mac's current client certificate `notAfter` is **Aug 17 12:22:41 2027 GMT**
(`openssl x509 -noout -enddate` on the client cert only). kubeadm will keep
honouring it until then.

Deleting `~/.kube/config` only removes **this copy of the key**. Anything that
already copied the file can still authenticate as `kubeadm:cluster-admins`.

What actually invalidates it sooner:

| Action | Cost |
|---|---|
| Wait until 2027-08-17 | None. Combined with deleting the Mac file, this is enough if the key did not leak |
| Rotate the **cluster CA** (`kubeadm` with a new CA, re-join nodes, re-issue every kubelet and admin cert, update trust on every client) | Cluster-wide outage and a new trust bundle everywhere. This is the only real revocation |

Recommend: **delete the Mac copy after the limited cert works**, keep admin.conf
only on `Master`, and rotate the cluster CA **only if** that admin key leaked.
Do not rotate the CA as part of this cutover.

## Checks

```sh
kubectl --kubeconfig private/k8s-access/<username>.kubeconfig auth can-i --list -n dev
kubectl --kubeconfig private/k8s-access/<username>.kubeconfig auth can-i get secrets --all-namespaces
kubectl --kubeconfig private/k8s-access/<username>.kubeconfig -n kube-system get pods   # viewer: yes; mutate: no
```
