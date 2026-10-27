# Vendored upstream manifests

Copied byte-for-byte from upstream so a sync never depends on GitHub being up, and an upgrade
shows up as a reviewable diff. Upgrade: download the new file, check it, update this table.

| File | Upstream | SHA-256 |
|---|---|---|
| `metallb/vendor/metallb-native-v0.14.8.yaml` | `https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml` | `11b5906021fde56040cf10d1bcbaf5c2b7a4206045ebb103915347dfcc533f0e` |
| `ingress-nginx/vendor/ingress-nginx-cloud-v1.11.3.yaml` | `https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/cloud/deploy.yaml` | `e043d5fde646af93e368a7cd379d76bf6383bb932229f61ad7635cc386124e96` |
| `argo-rollouts/vendor/argo-rollouts-install-v1.9.1.yaml` | `https://github.com/argoproj/argo-rollouts/releases/download/v1.9.1/install.yaml` | `78c82343803c2bbc13a36049e269a532dd67f25b7e2cb3603c99e31d8d8a40b5` |
| `argo-rollouts/vendor/argo-rollouts-dashboard-install-v1.9.1.yaml` | `https://github.com/argoproj/argo-rollouts/releases/download/v1.9.1/dashboard-install.yaml` | `e5ca7da00c597738e07b94c02731119a2ac00d49405f78a1c1d0737f7e93eff4` |
| `local-path/vendor/local-path-storage-v0.0.28.yaml` | `https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml` | `569fe4c806d8a967b3be1c97ead3dec5fa6931fc983c731a755c0e8ad82ea336` |
| `metrics-server/vendor/metrics-server-components-v0.8.1.yaml` | `https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.1/components.yaml` | `4a672c4891902573a3ff753cece5de1bf1f55dd053403dfec39df9d1636b7ff1` |

Check: `cd k8s/platform && shasum -a 256 */vendor/*.yaml`
