# Runbook: kube-prometheus-stack (control-plane scrapes)

The chart is Argo CD app `monitoring` (`k8s/platform/apps/monitoring.yaml`),
values in `k8s/platform/monitoring/values.yaml`, extras in
`k8s/platform/monitoring/manifests/`. Grafana login is the out-of-git Secret
`monitoring/grafana-admin`.

## Why kube-proxy / etcd / scheduler / controller-manager monitors are off

On this cluster those four processes bind their metrics ports on **127.0.0.1**
only (verified with `ss` on the nodes: kube-proxy 10249, etcd 2381,
kube-scheduler 10259, kube-controller-manager 10257). Prometheus scrapes the
node IPs, so the targets stay down and the default rules fire
`etcdInsufficientMembers`, `TargetDown`, and `*Unreachable` constantly.

The git values set `kubeProxy` / `kubeEtcd` / `kubeScheduler` /
`kubeControllerManager.enabled: false` and turn off the matching
`defaultRules.rules` (`etcd`, `kubeProxy`, `kubeControllerManager`,
`kubeSchedulerAlerting`, `kubeSchedulerRecording`). That is the low-risk
change: no host edits, no extra bind address on the control plane.

## Alternative: rebind so scrapes work (owner, host change)

Do **not** do this from an agent. It is a kubeadm change on the nodes:

1. On the control-plane, set ExtraArgs so etcd / kube-scheduler /
   kube-controller-manager listen on the node address (or 0.0.0.0) for their
   metrics ports, then `kubeadm init phase control-plane` / restart static
   pods as appropriate for this kubeadm version.
2. kube-proxy: `metricsBindAddress` in the kube-proxy ConfigMap (typically
   `kube-system/kube-proxy`), then roll kube-proxy.
3. Re-enable the four chart components and their default rules in
   `k8s/platform/monitoring/values.yaml` and let Argo sync.

Cost: those ports become reachable from the node IPs (and anything that can
route to them). Leave them loopback-only unless you actually want the alerts.

## Undo

Set the four `enabled` flags and the five `defaultRules.rules` keys back to
`true` in `values.yaml`. The ServiceMonitors and PrometheusRules return on the
next sync; the false alarms return with them until the processes listen off
loopback.

## Cluster certificate expiry (replaces KubeClientCertificateExpiration)

The `KubeClientCertificateExpiration` default rule is disabled (it fires permanently because the daily
operator certificate lives 8 hours by design). Check the long-lived kubeadm certificates instead, every
few months and before 2027-08 (the old admin client cert expires 2027-08-17):

```sh
ssh Master 'sudo kubeadm certs check-expiration'
```

kubeadm renews the control-plane certificates on each `kubeadm upgrade`; renew by hand with
`sudo kubeadm certs renew all` on master (owner step, then restart the static pods).
