# Runbook: serve the Argo Rollouts Gateway API plugin from inside the lab

Why: [ADR 0013](../adr/0013-gateway-api.md) wanted an initContainer and no GitHub download.
Live (until this change) fetched `gatewayapi-plugin-linux-amd64` v0.17.0 from GitHub at
every controller start, which needed NetworkPolicy `argo-rollouts-plugin-download-egress`
(`:443` to `0.0.0.0/0`). Git now copies the binary from
`registry.home.arpa/belleshop/rollouts-gatewayapi-plugin` into the existing `plugin-bin`
emptyDir and points `trafficRouterPlugins.location` at `file://…`.

Argo Rollouts v1.9.1 only SHA-256-checks **http(s)** plugins (`utils/plugin/downloader.go`).
The ConfigMap still records the digest for humans; the **enforced** check is `sha256sum -c`
in the initContainer before the copy.

Kubelet TLS trust for `registry.home.arpa` is already on the nodes
(`roles/containerd_registry`, Caddy local root in `certs.d`). Kyverno's extra CA mount is
only for in-pod HTTPS to Nexus; the initContainer does not talk to Nexus — the kubelet
pulls the image. `argo-rollouts` is default-deny but **not** Kyverno-enforced (`dev` only).

Do the owner steps **before** merging/syncing the Git change. Sync without the image
ImagePullBackOffs the controller and canaries stop.

## Why not Nexus raw + narrowed egress

That would keep a start-time HTTPS fetch, need a new Nexus raw repo, and need the
controller process to trust Caddy's local root (today only Kyverno and containerd do).
An initContainer reuses the existing pull path and **deletes** the internet egress rule
instead of shrinking it to `.87/32`.

## Owner steps (copy-paste)

Binary digest (GitHub release v0.17.0, already pinned in the ConfigMap):

`1904ca787d33107c140521899d61fff030ee75d99908bd175fca5a4647759061`

### 1. Copy `nexus-pull` into `argo-rollouts` (out of band, never git)

The Secret already exists in `dev` and `kyverno`. Same shape as the Kyverno notes:

```sh
ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n argo-rollouts get secret nexus-pull'
# expected before this step: NotFound
```

```sh
ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n dev get secret nexus-pull -o json' \
  | python3 -c '
import json, sys
s = json.load(sys.stdin)
s["metadata"] = {"name": "nexus-pull", "namespace": "argo-rollouts"}
print(json.dumps(s))
' | ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf apply --dry-run=server -f -'
# expected: secret/nexus-pull configured (server dry run)  OR created (server dry run)
```

Then apply without `--dry-run=server` (this one is a real write):

```sh
ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n dev get secret nexus-pull -o json' \
  | python3 -c '
import json, sys
s = json.load(sys.stdin)
s["metadata"] = {"name": "nexus-pull", "namespace": "argo-rollouts"}
print(json.dumps(s))
' | ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -'
```

### 2. Build and push the plugin image (`allow_once`: first tag wins)

One command from the Mac (repo root). It works on `ci-agent` in a root-only temp dir with its own
`DOCKER_CONFIG`, downloads the release and checks `sha256` before anything else, builds as `ci-pull`
(the busybox base comes through the `dockerhub` proxy), pushes as `ci-push`, prints the registry digest,
logs out and deletes the temp dir. Passwords go from `/etc/nexus/secrets/*` on `nexus` to
`docker login --password-stdin` on `ci-agent` over ssh stdin: never argv, never your terminal.
If the tag already exists it does not try to overwrite it.

```sh
scripts/rollouts-plugin-image.sh --dry-run   # download + sha256 + plan; no login, no push
scripts/rollouts-plugin-image.sh
```

Dry-run verified 2026-11-07 on ci-agent (`sha256sum: OK`, exit 0, no temp dir left). The login,
build and push path needs the registry credentials, so its first real run is the owner's.
Optional follow-up: put the printed digest on `images[].digest` in `k8s/platform/argo-rollouts/kustomization.yaml`.

### 3. Merge / sync, then confirm no GitHub fetch

```sh
kubectl kustomize k8s/platform/argo-rollouts | grep -A2 'location:'
# expected: file:///home/argo-rollouts/plugin-bin/gatewayapi-plugin-linux-amd64
kubectl kustomize k8s/platform/argo-rollouts | grep argo-rollouts-plugin-download-egress
# expected: no match
```

After Argo CD syncs `argo-rollouts`:

```sh
ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n argo-rollouts get pods -l app.kubernetes.io/name=argo-rollouts'
ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n argo-rollouts get netpol argo-rollouts-plugin-download-egress'
# expected: NotFound
ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n argo-rollouts logs deploy/argo-rollouts --tail=50' \
  | grep -E 'Copied plugin|Downloading plugin|Failed to download'
# expected: Copied plugin from /home/argo-rollouts/plugin-bin/gatewayapi-plugin-linux-amd64
# not: Downloading plugin … github.com
```

Rollback: revert the Git commit (restores the GitHub URL and the egress policy). The
controller will download again on next start. Leave `argo-rollouts/nexus-pull` in place
or delete it; nothing else uses it.

## Uncertain

- Exact CWD of `quay.io/argoproj/argo-rollouts:v1.9.1`. Relative `plugin-bin` is mounted at
  `/home/argo-rollouts/plugin-bin`, so the absolute `file:///` path is the safe choice.
- `RepoDigests[0]` vs Nexus repo digest: copy the digest from the Nexus UI if they differ.
