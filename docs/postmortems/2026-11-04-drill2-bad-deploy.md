# Postmortem: Drill 2, bad deploy that the canary analysis promoted, then a fix it blocked

- Date: 2026-11-04 (evening CST; 2026-11-05 UTC)
- Severity: **Medium** (planned drill that turned into a real 11-minute login outage for every BelleShop user;
  no data loss; no alert fired)
- Status: **Resolved 2026-11-04 20:33 CST.** Follow-ups in Action items
- Duration: login broken 20:22:12 to ~20:33:50 CST (about 11.5 min); detected only by a human watching
- Author: homelab-platform
- Drill: yes, [ADR 0018](../adr/0018-week8-chaos-drills.md) drill 2 (bad deploy, Rollouts abort)

## Summary

The drill shipped a bad **config** change through the normal git path (belleshop-deploy #28): the backend's
`MYSQL_HOST` pointed at a host that does not exist. Same signed image, so Kyverno admitted it; `/healthz` stayed
200 while `/token` and `/register` returned 500. Synthetic failed-login traffic (fake credentials, ~4 rps through
the canary-managed route) gave the analysis something to measure. **The hypothesis failed twice.** The
`success-rate` analysis **passed** the bad canary and promoted it to 100%. Then the revert (#29) went through the
same canary and was **aborted**, because the analysis counted the broken *stable* pods' errors against the good
canary. Recovery needed a manual `promoteFull`. The SLO never paged, because the probes check `/healthz`, not
login.

## Timeline (America/Chicago, CST)

| When | What |
|---|---|
| 2026-11-04 20:15:24 | Pre-check: Rollout Healthy, last analysis Successful, SLO Fast-burn inactive; synthetic failed-login load started (`POST /api/token`, ~4 rps, all 400) |
| 2026-11-04 20:18:59 | **Injection:** belleshop-deploy #28 merged by the owner (bad `MYSQL_HOST`) |
| 2026-11-04 20:21:06 | Argo CD synced; Rollout Progressing, new ReplicaSet `6db86b468f` |
| 2026-11-04 20:21:19 | Canary 10% (pause 15 s) |
| 2026-11-04 20:21:33 | Canary 50% (pause 15 s) |
| 2026-11-04 20:21:46 | AnalysisRun `backend-6db86b468f-16-4` Running (10 s × 3) |
| 2026-11-04 20:22:12 | **AnalysisRun Successful; bad version promoted to 100%.** Login 500 for every user from here |
| 2026-11-04 20:25:53 | **Detect (human):** watcher showed "Healthy 100%" on the bad revision; `curl /api/token` = 500 ×3; Prometheus `/token 5xx` 3.1 rps. No alert fired. SLO Fast-burn still inactive |
| 2026-11-04 20:28:24 | **Mitigate (attempt 1):** revert belleshop-deploy #29 merged (`MYSQL_HOST=mysql`) |
| 2026-11-04 20:29:24 | Fix canary 10%, then 50% at 20:29:50 |
| 2026-11-04 20:30:15 | **Fix ABORTED:** `Metric "error-rate-check" assessed Failed due to failed (2) > failureLimit (1)`; traffic stays on the broken stable; Rollout Degraded |
| 2026-11-04 ~20:33 | **Mitigate (attempt 2):** owner `kubectl -n dev patch rollout backend --subresource status` with `promoteFull: true, abort: false` |
| 2026-11-04 20:34:35 | **Recover:** Rollout Healthy, stable `975b94857` (`MYSQL_HOST=mysql`), login 400 ×4 (correct for fake credentials), Argo app Synced/Healthy |

## Root causes

1. **The analysis judged the canary before its evidence existed.** Three checks 10 s apart (30 s) on
   `rate(...[1m])`; the new pods' counters need at least two scrapes before `rate()` sees them, so every check
   measured only the healthy stable pods. The bad canary passed.
2. **The analysis measures the wrong pods.** The query sums `job="backend"` across stable and canary. Once the bad
   version was stable, its 500s made the *good* canary fail. A canary check that cannot tell canary from stable
   blocks rollbacks exactly when they matter.
3. **No-traffic counts as success.** Without the synthetic load the backend only serves `/healthz` and `/metrics`,
   the 5xx ratio is 0, and any broken non-health route ships. The drill had to inject its own traffic.
4. **The SLO watches the wrong thing for this failure.** The probes hit `/` and `/api/healthz`; `/healthz` does not
   touch MySQL, so a broken database path was invisible to the SLO and to every alert.

## What worked

- Signed-image admission was not bypassed: the bad change was config on the same signed digest, which is the
  realistic way such outages reach production.
- Git kept the audit trail: #28 injected, #29 reverted; the owner merged both (branch protection held; the bot
  cannot merge in belleshop-deploy).
- `promoteFull` through the status subresource rolled the fix forward in seconds without the Rollouts CLI (not
  installed on Master).
- The watcher's timeline made the analysis behaviour obvious and gave exact timestamps.

## What went badly

- An 11.5-minute outage of login with **no alert at all**; a human watching a terminal was the only detector.
- The ADR's expectation ("Rollouts aborts the bad canary") was wrong, and the rollback path through the same
  canary made recovery slower and needed a manual override.
- My recovery check treated 502 (pods swapping) as "recovered" because it only looked for 500. Fixed during the
  drill; the lesson is to check for the expected good code, not the absence of one bad code.

## Action items

- [ ] belleshop-deploy: canary-only analysis (filter by the canary pod-template hash), window longer than two
      scrape intervals (initialDelay, `rate[2m]`, 30 s × 4+), and a minimum-traffic guard that makes "no traffic"
      Inconclusive, not Success (PR in progress)
- [ ] SLO coverage for the database path: a synthetic probe that exercises a DB-backed route (for example a login
      with a dedicated probe account, expecting 400/200, never 5xx) or an alert on `/token` 5xx rate
- [ ] Runbook: "rollback blocked by the canary" procedure (`promoteFull` / `abort` via the status subresource), and
      install the `kubectl argo rollouts` plugin where operators work
- [ ] ADR 0018 drill 2: record that the hypothesis failed and why

## Lessons

1. **A canary check must measure the canary, over a window long enough to see it.** Otherwise it is a coin toss
   that happens to land on "pass".
2. **Your rollback path is a deploy too.** If it goes through the same gate, the gate must not punish the fix for
   the broken version's errors.
3. **"No errors" and "no traffic" look the same in a ratio.** Guard on request volume before trusting a success rate.
4. **Health checks that skip dependencies make SLOs blind to dependency failures.** Probe a path that uses them.
