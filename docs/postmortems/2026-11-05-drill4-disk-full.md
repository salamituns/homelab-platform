# Postmortem: Drill 4, disk full (a per-pod disk cap evicts a runaway writer; the node is unharmed)

- Date: 2026-11-05
- Severity: **Low** (planned; one throwaway pod on master evicted; no workload or node disk affected)
- Status: **Resolved 2026-11-05.** Clean-up merged (#73); owner deletes the Application and namespace
- Duration: eviction 48 s after the pod started; warning alert 2 min after the eviction
- Author: homelab-platform
- Drill: yes, [ADR 0018](../adr/0018-week8-chaos-drills.md) drill 4 (disk full)

## Summary

Filling a real node disk is unsafe in this lab: `local-path` does not enforce PVC sizes, and the node-level disk
alerts only fire at 5%/3% free, tens of GiB away and next to MySQL, Prometheus and Loki. So the drill tested the
control that stops one misbehaving pod from filling a node: an `emptyDir` with `sizeLimit: 256Mi`. A bare pod
`homelab-disk-canary`, pinned to the master (no PVC-backed workloads there), wrote 300 MiB and kept running. The
kubelet evicted it 48 s later; the new `HomelabDiskCanaryEvicted` alert (PR #66) fired; node free space did not
move. An independent read-only safety check by a second agent gave GO beforehand. The hypothesis held.

## Timeline (America/Chicago, CST)

| When | What |
|---|---|
| 2026-11-05 07:45-07:49 | Safety check (read-only): master 37.84% free (14.8 GiB), 8.6 GiB above the 15% imagefs eviction threshold after the write; `localStorageCapacityIsolation: true`; only the canary can be evicted by this path |
| 2026-11-05 09:24:31 | **Injection:** PR #72 merged. Baseline free: master 37.84%, workernode2 48.78%, workernode1 60.08% |
| 2026-11-05 09:31:07 | Pod scheduled on master (Argo CD took 6.5 min to apply the merge) |
| 2026-11-05 09:31:19 | Pod Running; `dd` writes 300 MiB into `/scratch` |
| 2026-11-05 09:32:07 | **Detect (kubelet):** `Failed / Evicted`: `Usage of EmptyDir volume "scratch" exceeds the limit "256Mi"`. `HomelabDiskCanaryEvicted` pending |
| 2026-11-05 09:34:06 | **Detect (alert):** `HomelabDiskCanaryEvicted` firing (warning, Alertmanager UI) |
| 2026-11-05 09:34:08 | After: master 37.80%, workernode2 48.77%, workernode1 60.06% (no movement beyond noise) |
| 2026-11-05 ~09:40 | **Recover:** revert PR #73 merged; owner deletes the Application (finalizer prunes the pod) and namespace |

## Root causes

1. **Real disk-full detection is late and the PVC layer is blind.** Node alerts fire at 5%/3% free after 30 min,
   and `kubelet_volume_stats_*` is absent with `local-path`, so `KubePersistentVolumeFillingUp` can never fire.
   A runaway writer on a PVC would fill the whole node silently until the 5% alert.
2. **Per-pod caps are the working control, but almost nothing uses them.** The safety check found no other pod on
   master with an `emptyDir.sizeLimit` or `ephemeral-storage` limit; across the cluster the cap exists only where we
   set it on purpose.

## What worked

- The kubelet enforced the cap quickly (48 s, within the expected 10-70 s) and evicted only the offender.
- Two-agent preparation: a builder and an independent read-only safety check that measured the margins, confirmed
  enforcement, and caught a trap (a pod that exits after writing is never evicted, so it must keep running).
- The drill's Application carried a resources finalizer, so deleting it cleans up the pod (drill 3 lesson applied).
- Must-not list held: no PVC filled, nothing run on a worker, node disks unchanged.

## What went badly

- Argo CD took 6.5 min to apply the merge (usually ~3 min), which stretches any "deploy a fix" path. Not investigated.
- The alert is a warning (UI only). A real repeating eviction would not page anyone.
- Clean-up still needs a manual Application delete because `platform-root` does not prune.

## Action items

- [ ] Add `ephemeral-storage` requests/limits (or `emptyDir.sizeLimit`) to BelleShop and the platform charts that
      write scratch data, so a runaway writer is evicted instead of filling a node
- [ ] Disk visibility for `local-path` PVCs: scrape kubelet volume stats or add a node-exporter textfile of PVC dir
      sizes, then make `KubePersistentVolumeFillingUp` meaningful
- [ ] Page (critical) when evictions repeat, e.g. more than 3 in 30 min cluster-wide
- [ ] Look at Argo CD's refresh interval / webhook from Gitea so merges apply in seconds, not minutes

## Lessons

1. **Test the control, not the catastrophe.** "Disk full" is unsafe to cause for real here; proving the per-pod cap
   works is the realistic, safe version, and it shows what actually protects the node.
2. **A safety check by someone else is worth having.** The independent check found the "pod must stay running" trap
   and quantified the margin before anything merged.
3. **No metric, no alert.** The PVC disk alert exists in the chart but can never fire without volume stats.
