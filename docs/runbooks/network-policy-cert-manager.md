# Runbook: NetworkPolicy for cert-manager (ADR 0015 section A, last round)

Own file on purpose (the shared network-policy.md runbook bit us in round 2: four
branches appending to one section conflicted on every merge). The general facts -
fail-open agent, post-DNAT evaluation, masquerade addresses, #417 noise - live in
`docs/runbooks/network-policy.md`; this file only covers what is specific to
`cert-manager`.

## What this namespace does

The controller issues the lab's TLS from the `lab-ca` ClusterIssuer (the intermediate
Secret the owner loads; no ACME, no external CA - ADR 0015 B), the cainjector injects
CAs into webhook configs, and the webhook validates every Certificate and
CertificateRequest write with **failurePolicy Fail** (read live). The wildcard leaf
`apps-home-arpa` (90 days, renewed at 30 days left) serves every Gateway route.

## The flows (netpol-allow.yaml + netpol-default-deny.yaml)

Every pod: DNS + API (192.168.1.90:6443), both at sync-wave "-1" - that is the whole
egress set, because the CA issuer signs locally from a Secret; the appendix "no
external ACME" row verified live against the ClusterIssuer and Services. Ingress:
cert-manager-webhook :443 (container port **10250**, live pod + Endpoints say 10250)
from 10.244.0.0/24, the master masquerade range - never 192.168.1.90/32. The 9402
metrics Services exist but nothing scrapes them (no ServiceMonitors, verified via the
admin path), so there is deliberately no monitoring ingress on 9402.

## The quiet failure (why this is checked most carefully)

Nothing user-visible breaks on the day the deny lands: the wildcard leaf keeps
serving for up to 60 days. A cut webhook shows up at the next Certificate write or
renewal. So after sync:

```sh
scripts/netpol-proof.sh cert-manager
```

It checks: the app Synced/Healthy, all three pods Ready, a dummy Certificate create
with `--dry-run=server` through cert-manager-webhook (persists nothing), a Gateway
route still serving the wildcard leaf (TLS works = the leaf is valid), the webhook
port DENIED from a dev pod, and the agent DENY verdicts.

**The limited kubeconfig cannot create anything anywhere** (verified live), so the
dummy-create check prints the owner command instead of running - run it over the
admin path after sync.

## Watch for an hour

Agent DENY verdicts naming cert-manager pods. A dst 192.168.1.90:6443 DENY on the
controller (10.244.4.227) means renewals are already broken even though every route
still serves. In Grafana, the cert-manager panel if wired; otherwise a weekly
`kubectl get certificate -A` over the admin path is the backstop.

## Rollback

Revert the PR (the cert-manager app prunes the manifests path source that ships both
files). If Certificate writes are locked up cluster-wide and waiting is not
acceptable, delete the deny over the admin path first - the allows are inert without
it:

```sh
ssh tunsadmin@192.168.1.90 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf \
  -n cert-manager delete networkpolicy cert-manager-default-deny'
```

If the webhook stays unreachable (Certificate writes fail with "failed calling
webhook"), delete `cert-manager-webhook-ingress` the same way.
