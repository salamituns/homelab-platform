# Postmortem: Proxmox firewall enable reactivated legacy 10.2.x NAT

- Date: 2026-11-03
- Severity: **High** (Argo CD, ESO and the LAN lost HTTP(S) to lab services for about 40 minutes; no data lost; SSH, the Kubernetes API and DNS were unaffected)
- Status: **Resolved 2026-11-03 ~12:05 CST.** Follow-ups in Action items
- Duration: about 40 minutes (11:24 to ~12:05 CST)
- Author: homelab-platform

## Summary

Enabling the Proxmox host firewall (ADR 0015 step 6, the input-ACCEPT stage) loaded `br_netfilter`
with `bridge-nf-call-iptables=1`. From that second, bridged traffic on `vmbr0` traversed the host
`nat` table, where legacy rules from the pre-`homelab` era (`-i vmbr0 --dport 80/443 -j DNAT
--to 10.2.0.2`) were still loaded and still restored at boot by two mechanisms. Every new
HTTP(S) connection from VMs without the NIC firewall flag (the three Kubernetes nodes) and from
the physical LAN to lab services was redirected to the retired 10.2.0.2 address. Argo CD lost
Gitea at 11:24 (the moment the firewall came up) and ESO lost OpenBao. VMs with `firewall=1`
NICs (sectools, gateway, gitea and others) ride `fwbr*` plumbing and were untouched, which is
why the first checks from sectools looked fine.

## Timeline (America/Chicago, CST)

| When | What |
|---|---|
| 2026-01 or earlier | Legacy 10.2.x DNAT/MASQUERADE rules set up on the hypervisor; later wired into `/etc/iptables.rules` (`post-up` in `/etc/network/interfaces`) and `/etc/iptables/rules.v4` (netfilter-persistent). Dormant in practice while nothing bridged through the nat table |
| 2026-11-03 11:24 | Owner runs `scripts/pve-firewall-stage.sh --policy=ACCEPT` (ADR 0015 step 6, stage 5). pve-firewall enables, `br_netfilter` sets `bridge-nf-call-iptables=1`, and Argo CD loses Gitea in the same second. ESO loses OpenBao; LAN HTTP(S) to `.240` and to VM services fails |
| ~11:35 | Host checks pass (Mac SSH, UI on 8006, sectools negative proof as expected under ACCEPT). The break is found by checking a **node**, not the Mac: `master` cannot reach `https://gitea.home.arpa` and the Argo CD apps show sync errors against the Git repo |
| ~11:45 | `iptables -t nat -S` on `tuns` shows the legacy `-i vmbr0 DNAT 10.2.0.2:80/443` rules as the cause; `br_netfilter` explains why they only now bite |
| ~11:50 | `scripts/pve-legacy-nat-cleanup.sh --dry-run` over Tailscale, then the real run: backup to `/root/homelab-legacy-nat-backup/`, live 10.2.x rules deleted, both restore-at-boot paths disabled |
| ~12:05 | HTTP(S) restored: Argo CD re-syncs Gitea, ESO reaches OpenBao again, `route-smoke.sh` matches baseline. The firewall stays enabled (input ACCEPT at that point; the DROP stage later passed with the negative proof from sectools: `curl https://192.168.1.181:8006` returns `000`, SSH times out) |

## Root causes

1. **Dormant state with two boot hooks.** The legacy rules were removed from live use long ago but
   kept re-loading at boot from two different files. Nothing flagged them because they matched
   traffic that (before this change) never traversed the host nat table.
2. **A firewall enable is a bridge-behaviour change.** `pve-firewall` loading `br_netfilter` with
   `bridge-nf-call-iptables=1` silently changed the datapath for every VM on `vmbr0`, not only
   for the host rules being reviewed. The pre-flight review covered the rules themselves, not
   which existing rules the new enforcement path would expose.
3. **Checks were host-shaped, not workload-shaped.** The stage checks verify SSH, the UI and
   (from sectools) the negative proof. None of them exercises a real workload flow from a node
   until `route-smoke.sh` and the Argo CD sync are read.

## What worked

- The dead-man timer and the iDRAC path were armed, so recovery never depended on a console.
- Tailscale (`root@100.81.210.111`) carried the whole fix; the LAN-side web UI was also reachable.
- The cleanup is a script in git with `--dry-run`, a one-time backup and an undo, not hand edits.
- The firewall itself did exactly what it was staged to do; the outage was caused by legacy
  state, not by the new rules. The DROP stage and the negative proof passed afterwards.

## Action items

- [x] Delete the legacy 10.2.x NAT rules live and at boot (`scripts/pve-legacy-nat-cleanup.sh`, PR #39, 2026-11-03)
- [x] Record the lessons in the runbook ([idrac-and-firewall.md](../runbooks/idrac-and-firewall.md), lessons from the 2026-11-03 apply): verify with a node, not the Mac; off-LAN use the host's own Tailscale address
- [ ] Remove the other legacy 10.2.x remnant on the host: the stale dnsmasq serving `homelab.local` (`scripts/pve-dnsmasq-retire.sh`, owner-run with `--dry-run`)
- [ ] Consider `firewall=1` plus explicit guest rules for the Kubernetes node VMs, so guest filtering is deliberate instead of defaulting to unfiltered bridging
- [ ] Pre-flight checklist for host firewall changes: dump `iptables-save` first and review every rule the enforcement path will start applying, not only the new ones

## Lessons

1. **Enabling enforcement is not an additive change.** It can activate years-old state that was
   invisible precisely because enforcement was off.
2. **A control that changes the datapath needs a proof that exercises the datapath.** Host checks
   pass while pods and VMs fail; the honest check is a node-to-service flow.
3. **Two restore paths for the same rules is one too many.** When retiring state, remove every
   mechanism that can bring it back, then prove it stayed removed.
