# Runbook: NetworkPolicy for external-secrets (ADR 0015 section A, last round)

Own file on purpose (the shared network-policy.md runbook bit us in round 2: four
branches appending to one section conflicted on every merge). The general facts -
fail-open agent, post-DNAT evaluation, masquerade addresses, #417 noise - live in
`docs/runbooks/network-policy.md`; this file only covers what is specific to
`external-secrets`.

## What this namespace does

The controller syncs secrets from OpenBao (`https://bao.home.arpa` = 192.168.1.95:443,
Caddy on sectools) into Kubernetes Secrets, the cert-controller patches the webhook
caBundle, and the webhook validates every ExternalSecret / SecretStore /
ClusterSecretStore write in the cluster with **failurePolicy Fail**. That last fact is
the whole risk of this PR: a wrong ingress rule on the webhook does not break this
namespace quietly, it rejects writes cluster-wide.

## The flows (netpol-allow.yaml + netpol-default-deny.yaml)

Every pod: DNS + API (192.168.1.90:6443). Controller additionally: OpenBao
192.168.1.95:443. Webhook additionally: ingress 443 (container port **10250**, live
pod + Endpoints say 10250, not the 9443 the ADR appendix guessed) from
10.244.0.0/24, the master masquerade range - never 192.168.1.90/32. All three pods:
metrics 8080 ingress from monitoring (three ServiceMonitors scrape them; without this
the `BelleShopDbEsoSyncFailed` alert goes silent exactly when it matters).

Waves: DNS and API egress are sync-wave "-1", the default-deny is wave "1" (the argocd
lesson: the first egress policy isolates, the deny must not land before the allows).

## Verify after sync

```sh
scripts/netpol-proof.sh external-secrets
```

It checks: the app Synced/Healthy, `dev/belleshop-db-eso` ExternalSecret Ready (the
controller -> OpenBao -> API path, end to end), a dummy ExternalSecret created with
`--dry-run=server` (runs the externalsecret-validate webhook, persists nothing), the
metrics port DENIED from a dev pod, and the agent DENY verdicts.

**The limited kubeconfig cannot create anything anywhere** (verified live), so the
dummy-create check prints the owner command instead of running - run it over the admin
path after sync. That is the one check this round adds that round 2 did not have.

## Watch for an hour

The `BelleShopDbEsoSyncFailed` alert (Week 5) and the ESO panel in Grafana: a cut
OpenBao flow shows up as ExternalSecrets losing Ready. Agent DENY verdicts naming
10.244.4.210 (the controller) with dst 192.168.1.95 mean the OpenBao rule is wrong.

## Rollback

Revert the PR (the app prunes both files; prune is enabled here). If writes are locked
up cluster-wide and waiting is not acceptable, delete the deny over the admin path
first - the allows are inert without it:

```sh
ssh tunsadmin@192.168.1.90 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf \
  -n external-secrets delete networkpolicy external-secrets-default-deny'
```

If the webhook was the broken piece, also delete `external-secrets-webhook-ingress`
the same way; with failurePolicy Fail an unreachable webhook rejects all writes to the
three ESO kinds in every namespace until it is reachable again.
