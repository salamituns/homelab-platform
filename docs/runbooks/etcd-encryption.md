# Runbook: etcd encryption at rest (ADR 0014 step 7)

Why and what: [ADR 0014](../adr/0014-secrets-and-identity.md). Secrets in etcd are stored
plaintext by default; anyone with the etcd data (a stolen disk, a leaked snapshot, a PBS copy of
the master VM) has every Secret. The API server now encrypts Secret values with `secretbox`
(XSalsa20 + Poly1305) before writing them, using a 32-byte key that lives only in
`/etc/kubernetes/enc/encryption-config.yaml` on the master, root, `0600`.

Provider choice: the [Kubernetes docs](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
rate `secretbox` **Strong** and **Faster** (32-byte keys), while `aescbc` is rated **Weak**
(CBC is vulnerable to padding-oracle attacks, "not recommended"). The docs' only caveat for
secretbox is that its primitives are newer than the conservative review standards some
environments require; that does not apply here. `configmaps` are NOT encrypted: they are public
configuration by design, and encrypting them adds etcd write cost for no confidentiality. If a
ConfigMap ever needs to hold sensitive data, it should become a Secret instead.

`identity: {}` stays as the second provider: existing Secrets remain readable in plaintext until
rewritten, and the API server falls back to it for anything not encrypted.

What lives where:

| Thing | Where |
|---|---|
| Key + EncryptionConfiguration | `/etc/kubernetes/enc/encryption-config.yaml`, master, root, `0600` |
| API server flags + hostPath volume | `/etc/kubernetes/manifests/kube-apiserver.yaml` and the `kubeadm-config` ConfigMap (`apiServer.extraArgs`/`extraVolumes`) so `k8s-upgrade.yml` regenerates them |
| etcd snapshot + pre-change manifest copy | `/root/etcd-encryption-backups/<timestamp>-pre-enable/`, master, `0700`/`0600` |
| Ansible automation | `ansible/playbooks/k8s-etcd-encryption.yml` |
| Rewrite script | `scripts/k8s-rewrite-secrets.sh` |

## 1. Enable (apply order)

```bash
cd ansible
ansible-playbook playbooks/k8s-etcd-encryption.yml --check --diff   # reads, manifest diff, server dry run of the ConfigMap patch
ansible-playbook playbooks/k8s-etcd-encryption.yml                  # snapshot FIRST, then enable
```

The playbook takes and verifies an etcd snapshot before touching anything, generates the key only
if the config file is absent (never overwrites one), writes the flags into both the static-pod
manifest and the kubeadm ClusterConfiguration, then waits for the new API server. The manifest
is patched with ONE atomic write (kubelet starts a pod for any file in
`/etc/kubernetes/manifests`, so a flag that arrives without its mount would crashloop the API
server), and the original manifest is kept beside the snapshot.

The wait cannot be fooled by the old server: the mirror pod `kube-apiserver-<node>` must carry
`--encryption-provider-config` AND be Ready AND `/readyz` must answer 200 before the playbook
says "enabled". Only then is it safe to rewrite.

Expected outage: one API server on one node. kubelet restarts the static pod within its manifest
sync period once the file changes, and the API server needs a few seconds to start and load the
encryption provider. Estimate **15-60 seconds** with no API answers. Running workloads are not
affected: kubelet keeps running pods alive without the API server, and they reconnect (ESO
retries its poll, `kubectl` waits at your terminal). This window is an estimate; it has not been
timed on this cluster yet.

If the wait task fails: the API server rejected the config. Put the original manifest back and
kubelet restarts the previous, working pod:

```sh
ssh tunsadmin@192.168.1.90 'sudo cp /root/etcd-encryption-backups/<timestamp>-pre-enable/kube-apiserver.yaml.pre-enc /etc/kubernetes/manifests/kube-apiserver.yaml'
```

Then, immediately after the playbook succeeds, **in this order**:

```bash
cd ..
# 1. Copy the key off the master BEFORE the rewrite (see step 3 for the command and why).
# 2. Rewrite every Secret so it is stored encrypted. The script refuses to run if the
#    running API server does not carry the flag.
scripts/k8s-rewrite-secrets.sh --dry-run
scripts/k8s-rewrite-secrets.sh
# 3. Defrag etcd to reclaim the plaintext revisions (step 4 below).
# 4. Verify (step 2 below).
# 5. Delete the plaintext pre-enable snapshot once the change has settled (step 4 below).
```

## 2. Verify

All reads below print only the first bytes of the stored value, which show the storage envelope,
never Secret data. Plain text in etcd starts with the bytes `k8s` (binary); encrypted values
start with the ASCII marker `k8s:enc:secretbox:v1:`.

A Secret that existed before (rewritten by the script):

```sh
ssh tunsadmin@192.168.1.90
sudo -i
kubectl exec -n kube-system etcd-master -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/dev/belleshop-secrets-eso --print-value-only | head -c 24; echo
# expected: k8s:enc:secretbox:v1:key1:
```

A Secret created after the change, and that the API still serves it:

```sh
kubectl -n default create secret generic etcd-enc-check --from-literal=probe="$(openssl rand -hex 16)"
kubectl exec -n kube-system etcd-master -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/etcd-enc-check --print-value-only | head -c 24; echo
# expected: k8s:enc:secretbox:v1:key1:
kubectl -n default get secret etcd-enc-check -o jsonpath='{.metadata.name}{"\n"}'   # still served
kubectl -n default delete secret etcd-enc-check
```

## 3. Key custody

**The key never appears in this repo, in a log or in a command line.** Copy it off the master in
your terminal, into the password manager, once:

```sh
ssh tunsadmin@192.168.1.90 'sudo grep "secret:" /etc/kubernetes/enc/encryption-config.yaml'
```

Do this BEFORE the rewrite, not after. Once Secrets are stored encrypted, a lost master without
an off-host key copy means every encrypted Secret is unrecoverable: the key exists nowhere else.
Copy first, rewrite second.

Facts to weigh (checked 2026-11-01):

- The PBS `daily-all` job backs up **all 15 VMs, master included** (see
  [backups.md](backups.md)), and PBS client-side encryption is still open there
  (`TODO(encryption)`). So PBS copies contain both the key file and the encrypted data. PBS
  protects against disk loss, not against key+data disclosure as one set.
- An etcd snapshot stored beside the key protects nothing: whoever holds the backup disk holds
  both. Snapshots in `/root/etcd-encryption-backups/` are for operational recovery, not custody.
- The off-host copy in the password manager is the real custody move: it survives a master
  rebuild, and rebuilding the cluster without the key would lose every Secret anyway.

## 4. Plaintext that remains after the rewrite

Encrypting new writes does not erase old copies. Three places keep plaintext after the rewrite
finishes:

**Old etcd revisions.** The rewrite writes a new revision of every Secret; the plaintext
revisions stay readable on disk until etcd compaction removes them (the API server compacts
automatically every 5 minutes by default; our manifest does not override
`--etcd-compaction-interval`). Compaction stops the old revisions being reachable, but the disk
space is only reclaimed by a defragmentation. On this single-member cluster `defrag` touches
only member and takes seconds at this data size; etcd briefly blocks writes during it, the API
server pauses with it, and running workloads are unaffected.

```sh
ssh tunsadmin@192.168.1.90
sudo -i
# wait at least one compaction interval after the rewrite (5 min), then:
kubectl exec -n kube-system etcd-master -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status -w table   # note DB SIZE before
kubectl exec -n kube-system etcd-master -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  defrag
# endpoint status -w table again: DB SIZE drops once compaction has removed the old revisions
```

**The pre-enable snapshot.** It contains every Secret in plaintext (it was taken before
encryption). Keep it `root:0600` while the change is being applied, and delete it once
verification passes:

```sh
ssh tunsadmin@192.168.1.90 'sudo rm -rf /root/etcd-encryption-backups/<timestamp>-pre-enable'
```

If it is still on the master when today's `daily-all` PBS run happens, PBS captures it and keeps
the plaintext for as long as its retention keeps that backup (see next point).

**Existing PBS backups of the master.** Every backup taken before this change stores the Secrets
in plaintext, and PBS retention is 7 daily / 4 weekly / 3 monthly copies
([backups.md](backups.md)). The last pre-encryption monthly copy ages out about three months
after the change; until then PBS still holds plaintext Secrets.

What does and does not age out by itself: the database password rotates every 24h (the OpenBao
static role), so old plaintext copies of it stop working quickly. The MySQL root password, the
app `SECRET_KEY` and the pull credentials do NOT rotate; they stay valid in every old plaintext
copy until they are rotated by hand, which is a separate decision this runbook does not prescribe.

## 5. Restore a snapshot

The snapshot restores like any kubeadm etcd snapshot, with one addition: the key. A snapshot from
after encryption is unreadable without `/etc/kubernetes/enc/encryption-config.yaml`; put that file
back first (password manager -> new master, `root:0600`) and make sure the kube-apiserver manifest
carries the flags (re-run the playbook; it is idempotent). A snapshot from **before** encryption
contains plaintext Secrets and reads back fine while `identity: {}` is the second provider.

`etcdctl` is not installed on the master (it lives in the etcd image), and during a restore the
API server and the etcd pod are stopped, so `kubectl exec` is unavailable: run the restore through
the etcd image already on the node, using containerd's `ctr`. **This procedure has not been
drilled yet**; do a PBS-style drill (restore-drill pattern in [backups.md](backups.md)) before
relying on it.

```sh
ssh tunsadmin@192.168.1.90
sudo -i
set -eu

# 1. Stop the control plane static pods and the kubelet
systemctl stop kubelet
mkdir /root/manifests-parked
mv /etc/kubernetes/manifests/{etcd,kube-apiserver,kube-controller-manager,kube-scheduler}.yaml /root/manifests-parked/

# 2. Restore the snapshot into a fresh data dir, in a one-shot container from the etcd image
mkdir -p /var/lib/etcd-restore
ETCD_IMAGE=$(awk '/image:/{print $2}' /root/manifests-parked/etcd.yaml)
ctr run --rm \
  --mount type=bind,src=/root/etcd-encryption-backups,dst=/backups,options=rbind:ro \
  --mount type=bind,src=/var/lib/etcd-restore,dst=/restore,options=rbind \
  "$ETCD_IMAGE" etcdctl-restore -- etcdctl snapshot restore \
  /backups/<timestamp>-pre-enable/etcd.db --data-dir /restore
# success check: /var/lib/etcd-restore/member now exists

# 3. Swap the data dirs and bring the control plane back
mv /var/lib/etcd "/var/lib/etcd-broken-$(date +%s)"
mv /var/lib/etcd-restore/member /var/lib/etcd   # restore puts the data under <data-dir>/member
mv /root/manifests-parked/*.yaml /etc/kubernetes/manifests/
systemctl start kubelet

# 4. Verify: pods return, Secrets read
kubectl get nodes
kubectl -n dev get secret belleshop-secrets-eso -o jsonpath='{.metadata.name}{"\n"}'
```

If the restored cluster predates the key (or you skip the key file), Secret reads fail with
decryption errors; restore the key file and restart the API server (its static pod) or re-run the
playbook.

## 6. Key rotation

The API server runs with `--encryption-provider-config-automatic-reload=true` (verified on the
v1.33.13 binary), so key rotation needs **no restart**: the API server reloads the file within
about a minute of the change.

```sh
ssh tunsadmin@192.168.1.90 'sudo vi /etc/kubernetes/enc/encryption-config.yaml'
```

1. Add the new key FIRST inside `secretbox.keys` (the first key encrypts new writes), keep the old
   key as the second entry (it still decrypts):
   ```yaml
        providers:
          - secretbox:
              keys:
                - name: key2
                  secret: <fresh 32-byte key: openssl rand -base64 32>
                - name: key1
                  secret: <old key>
          - identity: {}
   ```
2. Wait a minute for the reload, then rewrite all Secrets with `scripts/k8s-rewrite-secrets.sh`
   so every value moves to the new key.
3. Remove the old key from the file, wait a minute, and update the password manager entry. Keep
   the old entry until you are satisfied nothing old is left in etcd.

Out of order it breaks like this: removing the old key before the rewrite makes every
not-yet-rewritten Secret unreadable (put it back and re-run the script). Putting the new key
second and rewriting re-encrypts with the old key and gains nothing.

## 7. Undo

Order matters; each step is safe only after the previous one.

1. Put `identity: {}` FIRST in the providers list (edit
   `/etc/kubernetes/enc/encryption-config.yaml`). New writes become plaintext.
2. `scripts/k8s-rewrite-secrets.sh` rewrites everything, decrypting it.
3. Remove the flags from BOTH places, or the next upgrade re-adds them from the ConfigMap:
   ```sh
   # on the master: restore the pre-encryption manifest (one atomic write, same as applying it),
   # or delete the two --encryption-provider-config* lines, the enc volumeMount and the enc volume
   cp /root/etcd-encryption-backups/<timestamp>-pre-enable/kube-apiserver.yaml.pre-enc \
      /etc/kubernetes/manifests/kube-apiserver.yaml
   kubectl -n kube-system edit cm kubeadm-config   # restore apiServer: {} (remove extraArgs/extraVolumes)
   ```
   kubelet restarts the API server on the manifest change; wait for the mirror pod to be Ready
   again as in step 1.
4. Only then delete `/etc/kubernetes/enc/` and the key in the password manager.

What breaks if the order is violated:

- Removing the flags BEFORE the identity-first rewrite: the API server cannot decrypt what is
  stored, so every Secret read fails (service-account tokens, ESO, pods mounting Secrets).
  Recovery: put the flags back exactly as they were.
- Removing the key or deleting `/etc/kubernetes/enc/` before the flags are gone: same failure.
- Removing `identity: {}` before everything is encrypted (or before the undo rewrite): any
  plaintext Secret that remains becomes unreadable. Recovery: put identity back and rewrite.
