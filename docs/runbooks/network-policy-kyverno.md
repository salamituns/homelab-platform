# Runbook: NetworkPolicy for kyverno (ADR 0015 section A, last round)

Own file on purpose (the shared network-policy.md runbook bit us in round 2: four
branches appending to one section conflicted on every merge). The general facts -
fail-open agent, post-DNAT evaluation, masquerade addresses, #417 noise - live in
`docs/runbooks/network-policy.md`; this file only covers what is specific to `kyverno`.

## What this namespace does

Four controllers run the cluster admission chain: eleven webhooks read live,
failurePolicy **Fail** on nine of them (only kyverno-ttl-validating and
kyverno-verify-mutating are Ignore). A wrong rule here does not fail quietly - it
rejects pod, policy and exception writes in every namespace. The one flow that breaks
differently: `verify-belleshop-images` (live ImageValidatingPolicy, failurePolicy Fail)
fetches Cosign signatures and SPDX attestations from `registry.home.arpa`
(192.168.1.87:443, verified live) at admission. Cut that and BelleShop deploys stop
at admission with "signature verification failed".

## The flows (netpol-allow.yaml + netpol-default-deny.yaml)

Every controller: DNS + API (192.168.1.90:6443), both at sync-wave "-1". The
admission controller additionally: 443 to 192.168.1.87 (registry signatures). Ingress:
kyverno-svc :443 (container 9443) and kyverno-cleanup-controller :443 (9443) from
10.244.0.0/24, the master masquerade range - never 192.168.1.90/32. The 8000 metrics
Services exist but nothing scrapes them (no ServiceMonitors, verified via the admin
path), so there is deliberately no monitoring ingress on 8000.

## Why the registry rule is the whole lab, not just this namespace

`restrict-registries` forces every image in enforced namespaces to start with
`registry.home.arpa/`, and `insecureIgnoreTlog`/`insecureIgnoreSCT` disable the
internet transparency-log lookups - so the registry IP is the only external fetch
kyverno needs. If the registry ever moves, this rule and the kyverno-policies globs
move together.

## Verify after sync

```sh
scripts/netpol-proof.sh kyverno
```

It checks: the app Synced/Healthy, all four controller pods Ready, a dummy pod
create with `--dry-run=server` that runs the full admission chain including the
registry signature fetch (persists nothing), kyverno-svc :9443 DENIED from a dev pod
(only the apiserver may call the webhooks), and the agent DENY verdicts.

**The limited kubeconfig cannot create anything anywhere** (verified live), so the
dummy-create check prints the owner command instead of running - run it over the
admin path after sync, then run a REAL deploy too: the round-2 lessons say kyverno
failures only show up under one (the dummy proves the path, a deploy proves the
verdicts).

## Watch for an hour

Agent DENY verdicts naming kyverno pods. The dangerous line is the admission
controller (10.244.4.170) with dst 192.168.1.87 - that is a cut signature fetch and
the next BelleShop deploy fails at admission. Also run one Argo CD sync of any app:
it writes pods through this admission chain.

## Rollback

Revert the PR (the app prunes both files). If admission is locked up cluster-wide and
waiting is not acceptable, delete the deny over the admin path first - the allows are
inert without it:

```sh
ssh tunsadmin@192.168.1.90 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf \
  -n kyverno delete networkpolicy kyverno-default-deny'
```

If a webhook is still unreachable after that (a pod, policy or exception write fails
with "failed calling webhook"), delete the two webhook-ingress policies the same way:
`kyverno-admission-webhook-ingress` and `kyverno-cleanup-webhook-ingress`.
