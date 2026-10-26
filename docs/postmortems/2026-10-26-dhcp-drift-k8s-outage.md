# Postmortem: Kubernetes outage after the router DHCP pool change

- Date: 2026-10-26
- Severity: **High** (Kubernetes API and BelleShop down; no data lost)
- Status: **Resolved 2026-10-26 ~09:05 CDT.** Follow-ups in Action items
- Duration: about 1 hour (start estimated from the master's DHCP lease timer)
- Author: homelab-platform

## Summary

Seven legacy VMs (the three Kubernetes nodes, SonarQube, Jenkins, Nexus, Tomcat) were documented
with fixed addresses (`.84-.90`) but were configured for **DHCP**: their router leases only happened
to match. On 2026-10-25 the router pool was narrowed to `.100-.180` to keep it away from the lab's
static range. Each VM kept its old address until its lease renewed, then received a new one from
the pool. When the master moved (`.90` -> `.137`), the Kubernetes API became unreachable: its
certificate, etcd and every kubelet are bound to `.90`. BelleShop went down with it.

## Timeline (America/Chicago)

| When | What |
|---|---|
| 2026-10-25 evening | Router DHCP pool changed from `.64-.253` to `.100-.180` (Week 1.5; protects the gateway's `.96` from being leased) |
| 2026-10-26 morning | Leases renew one by one: SonarQube `.132`, Nexus `.133`, Jenkins `.134`, workers `.135`/`.136` |
| ~07:55 | Master's lease renews: `.90` -> `.137`. Kubernetes API down; BelleShop unreachable |
| ~08:45 | Found while investigating why SonarQube, Jenkins and Nexus refused SSH (incident 2026-10-25 follow-ups): all three on DHCP. Survey of the other legacy VMs shows the k8s nodes and Tomcat on DHCP too; `kubectl` times out |
| ~08:55 | `ansible/roles/static_ip` written: netplan static address, cloud-init network config disabled, apply detached, reconnect, assert. Host keys checked with `HostKeyAlias` against the recorded keys for the documented IPs |
| ~09:00 | Master back on `.90`: API `livez ok` with no Kubernetes change |
| ~09:05 | Workers, SonarQube, Nexus, Jenkins, Tomcat back on their documented addresses. Nodes re-registered on `.89`/`.84`; two crash-looping pods (MetalLB speaker, kube-state-metrics) restarted; 40/40 pods Running; BelleShop 200; Argo CD Synced |

## Root causes

1. **Documentation said static, configuration said DHCP.** The legacy VMs came from a template whose
   cloud-init network config is `dhcp4: true`. Nothing compared the two.
2. **A DHCP pool change is a delayed change.** Its effect arrives at each host's next lease renewal
   (up to the lease time later, 24 h here), long after the change looks finished.
3. **No monitoring.** The API was down for about an hour and was found by accident.

## What worked

- The Proxmox guest agent gave read-only access to VMs that had no reachable address, and was the
  planned rollback path (`qm guest exec <vmid> -- sh -c 'rm /etc/netplan/60-static.yaml && netplan apply'`).
- Restoring the master's address was enough to bring the cluster back: no etcd or certificate work.
- The fix is code (`static_ip` role, addresses in `ansible/inventory/hosts.yml`), not hand edits.

## Action items

- [x] Pin the 7 legacy VMs to their documented addresses (`playbooks/static-ip.yml`, 2026-10-26)
- [ ] Week 7: probe the Kubernetes API and BelleShop from outside the cluster and alert on failure
- [ ] Network changes get a "who depends on this, and when does it take effect" line in the change
      notes (DHCP, DNS TTLs, certificates, leases)
- [ ] When the legacy VMs are rebuilt with Terraform, the address comes from code (`ipv4_address`), like `gitea`
- [x] SonarQube, Jenkins, Nexus: drop the legacy `10.2.0.0/21` ufw rule; open service ports to named clients only (`playbooks/cicd-firewall.yml`, 2026-10-26)

## Lessons

1. **A control plane on DHCP is an outage on a timer.** Kubernetes nodes, DNS servers and anything
   others connect to by IP need addresses set in code.
2. **"Documented" is not "configured."** Check the running system, not the inventory.
3. **Some changes land later.** A change to leases, TTLs or expiry dates finishes when the clock says so,
   not when the command returns.
