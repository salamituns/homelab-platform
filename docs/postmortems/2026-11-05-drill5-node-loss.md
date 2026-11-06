# Postmortem: Drill 5, node loss (ACPI shutdown of workernode1 / VM 107)

- Date: 2026-11-05
- Severity: **Medium** (planned; BelleShop API/login down ~7.5 min for every user; no data loss)
- Status: **Resolved 2026-11-05 ~16:49 CST.** Follow-ups in Action items
- Duration: detect ~2 min; recover ~4.5 min from power-on to fully green; shop impact ~7.5 min
- Author: homelab-platform
- Drill: yes, [ADR 0018](../adr/0018-week8-chaos-drills.md) drill 5 (node loss)

## Summary

The owner ACPI-shut down **workernode1** (VM **107**) with `qm shutdown 107 --timeout 180` and started it
again inside five minutes, before the default 300 s unreachable window. Prometheus on workernode2 kept
evaluating rules. `HomelabKubeNodeNotReadyFast` fired at two minutes; **no email arrived** because
Alertmanager is a single PVC-pinned replica on the node that died. Blackbox lived on the same node, so
SLO probes went **absent**, not 0. kubectl still listed those pods as Running while the node was
`Ready=Unknown`. Nothing rescheduled, nothing was Evicted. After `qm start 107`, MySQL came back on
the existing local-path volume (wrong-password `POST /api/token` → 400). The short-window hypothesis
in the [drill 5 runbook](../runbooks/chaos-drills.md) held. ADR 0018's original 10-minute TargetDown
detector was not reached on purpose.

## Timeline (America/Chicago, CST)

Watcher log is UTC; CST = UTC−6. Injection and start times from the owner.

| When | What |
|---|---|
| 2026-11-05 16:40:28 | Pre-check: workernode1 Ready, shop probes 1/1/1, no firing node-down alerts |
| 2026-11-05 ~16:42 | **Injection:** owner `qm shutdown 107 --timeout 180` |
| 2026-11-05 16:42:10 | Blackbox `probe_success` series **vanished** (exporter on wn1). Probes absent, not 0 |
| 2026-11-05 16:42:59 | workernode1 `Ready=Unknown`. `HomelabKubeNodeNotReadyFast` **pending**. kubectl still showed 0 pods not Running (stale) |
| 2026-11-05 16:44:12 | **Detect:** `HomelabKubeNodeNotReadyFast` **firing** (critical, `for: 2m`, `up{job="node-exporter"}==0`). Grafana / Prometheus UI. **No email** (owner, 16:44–16:50 CST) |
| 2026-11-05 ~16:45 | **Mitigate:** owner `qm start 107` (inside the 5 min / sub-300 s window). Never `qm stop` |
| 2026-11-05 16:47:32 | workernode1 Ready. 23 pods not Running (restarting on wn1). Fast alert still firing |
| 2026-11-05 16:48:27 | Fast alert cleared |
| 2026-11-05 16:48:47 | Shop probes 1/1/1 again |
| 2026-11-05 16:49:40 | **Recover:** 0 pods not Running. `mysql-0`, Alertmanager, `argocd-application-controller-0`, blackbox, `oauth2-proxy-alertmanager` each restarted once on wn1. `loki-0` Ready ~40 s later (memberlist rejoin 39 s) |
| after recover | Shop login `POST /api/token` with a wrong password → **400** (backend reaches MySQL; data intact). No PBS restore. 0 Evicted events; no reschedule onto workernode2 |

Live check after the drill (2026-11-05 ~16:52 CST): all three nodes Ready; all pods Running/Completed;
`mysql-0` / `loki-0` / Alertmanager Running on workernode1; shop-home/shop-api/shop-api-debug
`probe_success=1`; `https://belleshop.apps.home.arpa/` and `/healthz` 200; Grafana login 200;
`HomelabKubeNodeNotReadyFast` not firing.

## Root causes

1. **Alertmanager is a single replica pinned by local-path to the node we shut off.** The critical
   rule evaluated on Prometheus (workernode2) and had nowhere to send mail. Owner decision before
   the drill: **do not move Alertmanager**. That placement is the finding, not an oversight on the day.
2. **Blackbox is 1/1 on workernode1.** When the node dies, `probe_success` goes absent. SLO burn
   rules that need 0s never see them, so BelleShop availability alerting is blind for the same window.
3. **`Pod.Status=Running` is the last kubelet report, not liveness.** Until the node is Ready again
   (or the unreachable taint has sat for 300 s), kubectl will lie. The node condition is the signal.

## What worked

- Detection matched the pre-drill rule: `HomelabKubeNodeNotReadyFast` (PR #66) at ~2 min on
  Prometheus/Grafana while the node was Unknown. `TargetDown` (`for: 600`) correctly did not fire
  in a ~5 min window.
- Rollback was `qm start 107`. PVC-pinned MySQL/Loki/Alertmanager remounted; no PBS restore.
- No stampede: staying under 300 s meant zero reschedules and zero Evicted events on workernode2.
  Gateway VIP `.240`, Grafana, and Prometheus stayed up.
- Must-not list held: VMs 102/108/120/122/123 were not touched; no `qm stop`; no drain.

## What went badly

- **No page.** Critical alert, empty inbox. Watchdog could not leave the cluster either.
- **SLO series went absent**, so a real shop outage on this node would not burn Fast/Medium until
  blackbox is elsewhere or an `absent()` rule exists.
- **kubectl looked healthy** for the first minutes (`podsNotRunning=0` while Ready=Unknown).
- The original ADR detector (`TargetDown` at 10 min) was never exercised; doing so would pass the
  300 s reschedule and the still-open **BestEffort Prometheus/Grafana eviction risk past ~5 m 40 s**
  on a packed workernode2. That risk is unchanged.

## Action items

Owner decides; not implemented in this PR.

- [x] Alerting co-located with the failure: Alertmanager **2 replicas + anti-affinity**
      (`fu-alertmanager-ha`) **and** an external dead-man's-switch (Watchdog →
      healthchecks.io, `fu-deadman-switch`). HA email still dies if both workers or
      tuns/WAN die; the heartbeat is what pages then. Proven by silence drill 5 Nov
      20:05 CST: DOWN email ~10 min after last ping, UP on resume (see
      [monitoring runbook](../runbooks/monitoring.md)).
- [x] Blackbox on one worker blinds SLO alerts. Options: `absent()` / `absent_over_time` on
      `probe_success`, or blackbox replicas spread across nodes. (Both shipped.)
- [ ] Runbook: check **node Ready first**; do not trust `Running` on an unreachable node. Point
      [chaos-drills.md](../runbooks/chaos-drills.md) Drill 5 watch steps at `kubectl get nodes`.
- [ ] Prometheus/Grafana BestEffort (no memory limits) eviction risk on workernode2 if a node-loss
      window exceeds ~5 m 40 s — still open from the safety review. Do not extend a future drill
      past 300 s until that is bounded.

## Lessons

1. **A critical alert with the notifier on the dead node is a log line, not a page.** Put
   Alertmanager (or a heartbeat) somewhere that survives the failure it is meant to report.
2. **Absent is not zero.** Probes that disappear suppress SLO burn; treat missing `probe_success`
   as its own alert.
3. **Believe the node, not the pod list.** `Ready=Unknown` plus `Running` means the kubelet has
   not been heard from, not that the workload is up.
4. **The 300 s unreachable clock is the stampede.** A short ACPI bounce proves detection without
   packing the surviving worker; a 10-minute TargetDown wait is a different, riskier drill.
