# ADR 0009: metrics-server with verified kubelet TLS (CA-signed kubelet serving certificates)

- Status: Accepted
- Date: 2026-10-27

## Context

Week 2 asks for metrics-server (`kubectl top`, HorizontalPodAutoscalers). metrics-server scrapes every
kubelet on `:10250` and sends its ServiceAccount token with each request.

The kubelets serve self-signed certificates (`CN=<node>-ca@<timestamp>`, SAN = hostname only, no IP).
metrics-server cannot verify those, and the usual fix is `--kubelet-insecure-tls`. With that flag
anything on the LAN that answers for a node IP receives metrics-server's token and can feed it fake
CPU numbers, which HPAs then act on.

## Decision

| Question | Choice | Why |
|---|---|---|
| Version | metrics-server **v0.8.1** | v0.8.x supports Kubernetes 1.31+; v0.9.0 needs 1.34 |
| Install | Vendored upstream `components.yaml`, Argo CD app `metrics-server` (ADR 0008) | Same pattern as the other add-ons |
| Kubelet TLS | `serverTLSBootstrap: true` on every kubelet (`ansible/playbooks/kubelet-serving-certs.yml`) and in kubeadm's `kubelet-config` ConfigMap | Serving certificates from the cluster CA with the node IP; metrics-server verifies them with the CA it already trusts |
| CSR approval | `scripts/approve-kubelet-serving-csrs.py`: approves a `kubelet-serving` CSR only if it matches what the cluster records for that node | Kubernetes never auto-approves these: a node could ask for any name or IP |
| Not now | API server -> metrics-server still uses upstream's `insecureSkipTLSVerify: true` on the APIService | Fixing it needs a certificate issuer (cert-manager, Week 6) |

## Consequences

- Kubelet serving certificates expire after a year and rotate with a new CSR. Until it is approved,
  `kubectl logs/exec` on that node fail with `tls: internal error`. Run the approval script on each
  rotation; an automatic approver (e.g. kubelet-csr-approver) is a later option.
- An unavailable metrics API breaks API discovery: kubectl warnings, and namespace deletion hangs.
  So the kubelet certificates come first, metrics-server second.
- A new node joined with kubeadm inherits `serverTLSBootstrap` from the ConfigMap; approve its CSR.
