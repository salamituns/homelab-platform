# Postmortem: [short title — what actually broke]

- Date: YYYY-MM-DD
- Severity: **Low | Medium | High** (who felt it; whether data was at risk)
- Status: **Resolved YYYY-MM-DD ~HH:MM CST.** Follow-ups in Action items
- Duration: detect → recover (CST)
- Author: homelab-platform
- Drill: yes — ADR 0018 / [node-loss | disk-full | bad-deploy | expired-cert | leaked-secret] | no — unplanned

## Summary

One short paragraph: what we injected or what failed, what the user-visible effect was, and
whether the hypothesis in [ADR 0018](../adr/0018-week8-chaos-drills.md) held. No secret
values. No credential material.

## Timeline (America/Chicago, CST)

| When | What |
|---|---|
| YYYY-MM-DD HH:MM | Pre-checks (nodes Ready, probes 1, Watchdog firing, baseline `notAfter` / nodefs %) |
| YYYY-MM-DD HH:MM | **Injection** (PR merge / `qm shutdown 107` / rotate / …) |
| YYYY-MM-DD HH:MM | **Detect** — first signal (alert name + severity, Rollout aborted, gitleaks hook, UI) |
| YYYY-MM-DD HH:MM | **Mitigate** — revert merged / `qm start` / abort canary / rotate complete |
| YYYY-MM-DD HH:MM | **Recover** — probes 1, TargetDown inactive, weights 100/0, node Ready, login works |

Fill every row that applies. Keep times to the minute. If an expected alert did **not** fire,
write that on the detect row instead of leaving it blank.

## Root causes

1. **[Why the failure existed, not the injection command.]**
2. **[Why detection was late, missing, or surprising.]**
3. **[Why rollback was easy or not.]**

For a planned drill, "we shut off the VM" is not a root cause. "Alertmanager is a single
replica pinned by local-path to the node we shut off, so the page never left the cluster"
is.

## What worked

- Detection that matched the ADR (name the live rule, the hook, or the Rollouts abort).
- Rollback path (git revert, `qm start`, `--overwrite`).
- Must-not list: Gitea, OpenBao, PBS, wildcard TLS, the other worker, master.

## What went badly

- Alerts that should have fired and did not (include `for:` and why — stale series, AM down, missing scrape).
- Blast larger than planned (pods that moved, SLO page during a canary, nodefs movement).
- Extra manual steps that were not in the ADR.

## Action items

- [ ] Concrete follow-up with a PR or runbook pointer
- [ ] Detection gap from this drill (PrometheusRule + `promtool` test, ServiceMonitor, Gitea hook)
- [ ] Update [ADR 0018](../adr/0018-week8-chaos-drills.md) if the live facts changed

## Lessons

1. **[Portable sentence.]**
2. **[Portable sentence.]**
3. **[Portable sentence.]**
