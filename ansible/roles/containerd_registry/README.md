# Role: `containerd_registry`

Makes containerd on the k8s nodes (`Master`, `WorkerNode1`, `WorkerNode2`) trust the lab registry's
TLS certificate, so pods can pull images from `registry.home.arpa` (Nexus behind Caddy, per
[ADR 0011](../../../docs/adr/0011-ci-platform-rebuild.md)). Caddy serves the registry with
`tls internal`, so the CA is Caddy's local root certificate, which the `nexus` role fetches to
`ansible/files/ca/nexus-caddy-root.crt`.

## What It Does

Nothing is installed or downloaded, so there is no version pin or checksum. Per entry in
`containerd_registries` the role writes:

- `/etc/containerd/certs.d/<host>/ca.crt` (0644) - the registry's CA, copied from the controller.
- `/etc/containerd/certs.d/<host>/hosts.toml` (0644) - tells containerd's CRI plugin to pull and
  resolve from `https://<host>` and to verify the server against that `ca.crt`.

It then checks that containerd's CRI registry `config_path` includes `/etc/containerd/certs.d`
(containerd 2.x only reads the `hosts.toml` files when it does). On the lab nodes it already does,
so normally nothing else happens. If a node were configured differently, the role edits
`/etc/containerd/config.toml` to set `config_path` and restarts containerd through a handler.

## What the Nodes Actually Run (checked 2026-10-29)

All three nodes: containerd.io 2.2.1, config version 3, and in
`[plugins.'io.containerd.cri.v1.images'.registry]`:

```toml
config_path = '/etc/containerd/certs.d:/etc/docker/certs.d'
```

So on these nodes the role changes only the two files above; `config.toml` is left alone and
containerd is not restarted. The `config_path` edit is a safety net that keeps the role correct on
a rebuilt node whose `config.toml` comes out of the containerd.io defaults (empty `config_path`).

## A containerd Restart Does Not Stop Running Pods

`containerd` is not in a pod's process tree: the `containerd-shim` processes keep the containers
alive independently and the kubelet reconnects to the fresh socket. The worst case is a short
window in which new image pulls fail. This is also why the playbook runs with `serial: 1` - if the
restart is ever needed, it happens on one node at a time.

## Variables (`defaults/main.yml`)

| Variable | Default | Purpose |
|---|---|---|
| `containerd_registries` | `[{host: registry.home.arpa, ca_src: .../files/ca/nexus-caddy-root.crt}]` | Registries to trust; `ca_src` is a controller-side path |
| `containerd_registry_certs_d` | `/etc/containerd/certs.d` | Directory containerd reads per-registry `hosts.toml` from |
| `containerd_registry_section_re` | regex | Locates the CRI v1 images registry section in `config.toml` |
| `containerd_registry_config_path_re` | regex | Extracts that section's `config_path` value |

## Usage

```sh
cd ~/homelab-platform/ansible
ansible-playbook playbooks/k8s-registry-trust.yml --check --diff
ansible-playbook playbooks/k8s-registry-trust.yml
```

After the first run, test one pull per node (no kubectl needed):

```sh
ssh tunsadmin@192.168.1.89 'sudo ctr images pull registry.home.arpa/belleshop/web:TAG'
```

## Out of Scope

- The `k8s-pull` imagePullSecret (ADR 0011) is a cluster object, not node configuration; create it
  by hand or from manifests before the first sync that references `registry.home.arpa`.
- Signature verification at admission is Week 4 (Kyverno); this role only wires up the TLS trust.
