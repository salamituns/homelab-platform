# Vendored upstream manifests

Copied byte-for-byte from upstream so a sync never depends on GitHub being up, and an upgrade
shows up as a reviewable diff. Upgrade: download the new file, check it, update this table.

| File | Upstream | SHA-256 |
|---|---|---|
| `metallb/vendor/metallb-native-v0.14.8.yaml` | `https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml` | `11b5906021fde56040cf10d1bcbaf5c2b7a4206045ebb103915347dfcc533f0e` |
| ~~`ingress-nginx/vendor/ingress-nginx-cloud-v1.15.1.yaml`~~ | removed 2026-10-31 with the ingress-nginx app (ADR 0013) | — |
| `argo-rollouts/vendor/argo-rollouts-install-v1.9.1.yaml` | `https://github.com/argoproj/argo-rollouts/releases/download/v1.9.1/install.yaml` | `78c82343803c2bbc13a36049e269a532dd67f25b7e2cb3603c99e31d8d8a40b5` |
| `argo-rollouts/vendor/argo-rollouts-dashboard-install-v1.9.1.yaml` | `https://github.com/argoproj/argo-rollouts/releases/download/v1.9.1/dashboard-install.yaml` | `e5ca7da00c597738e07b94c02731119a2ac00d49405f78a1c1d0737f7e93eff4` |
| `local-path/vendor/local-path-storage-v0.0.28.yaml` | `https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml` | `569fe4c806d8a967b3be1c97ead3dec5fa6931fc983c731a755c0e8ad82ea336` |
| `metrics-server/vendor/metrics-server-components-v0.8.1.yaml` | `https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.1/components.yaml` | `4a672c4891902573a3ff753cece5de1bf1f55dd053403dfec39df9d1636b7ff1` |

| `nginx-gateway/vendor/gateway-api-standard-v1.6.3.yaml` | `https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml` | `356c2b8e286a964dc20995435659ad1095386329974793af10bbfe3eff977fe5` |
| `nginx-gateway/vendor/ngf-crds-v2.8.0.yaml` | `https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.8.0/deploy/crds.yaml` | `a652a8cdbade3a7663de77c4b293844f2126ac0a18421310129adac61bf926af` |
| `nginx-gateway/vendor/ngf-deploy-v2.8.0.yaml` | `https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.8.0/deploy/default/deploy.yaml` | `6f01716982e32be93d09917abf8ea17a06d0983855e67f37fb4f60de1d0f41f2` |

Check: `cd k8s/platform && shasum -a 256 */vendor/*.yaml`
