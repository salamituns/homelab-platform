# Runbook: iDRAC recovery path, then the Proxmox host firewall

Owner-only. ADR 0015 section C, ADR 0003. Scripts: `scripts/idrac-setup.sh`,
`scripts/pve-firewall-stage.sh`. Do not let an agent apply either without
`--dry-run`. Do not reboot while a 15-minute timer is armed (the timer dies on
reboot; `pve-firewall stop` is also undone by a reboot).

Addresses (checked 2026-11-03):

| What | Value |
|---|---|
| Hypervisor | `tuns` `192.168.1.181` |
| Mac LAN | `192.168.1.121` (`clients.yml`) |
| iDRAC new | `192.168.1.182/24` gw `192.168.1.254` (ping/arp free; not in `dns.yml`; outside DHCP `.100-.180`) |
| iDRAC old | dedicated, `10.2.6.180/13` gw `10.2.0.1`, active NIC `None` |
| Tailscale on tuns | `100.81.210.111`, grant tcp 22 and 8006 (`tailscale/policy.hujson`) |
| sectools (negative proof) | `192.168.1.95` |

## 0. Dry-run (any time)

```sh
scripts/idrac-setup.sh --dry-run
scripts/pve-firewall-stage.sh --dry-run
scripts/pve-firewall-stage.sh --dry-run --policy=DROP
```

## 1. iDRAC first, and test it from the Mac

`at` is not installed on tuns; the script uses `systemd-run --on-active=15m`.

Password handling: `ipmitool user set password 2 <pw>` would put the password
in the process list on tuns. The script writes an `ipmitool exec` file over ssh
stdin (mode 0600), runs `ipmitool exec` (argv is the filename only), shreds the
file. Prefer a pipe, not a shell history line:

```sh
read -rs IDRAC_PW
printf '%s' "$IDRAC_PW" | scripts/idrac-setup.sh
unset IDRAC_PW
```

That apply:

1. Sets user 2's password.
2. `ipmitool lan set 1 access on` (channel 1 Access Mode is **disabled** today;
   a new IP alone would still not accept sessions).
3. `ipmitool delloem lan set "shared with lom1"` (13G / iDRAC8; LOM1 = nic0,
   the only cabled NIC; failover none vs `shared with failover lom2`).
4. Static `192.168.1.182`.
5. Arms `homelab-idrac-revert.timer` which restores **dedicated + 10.2.6.180**.
   It does not restore the old password (unknown after rotation).

racadm is not on tuns, so IP-range filtering is **not** applied by the script.
After the UI answers, set iDRAC **IP Range** to `192.168.1.121/32` in the web UI
(iDRAC.IPBlocking). Licence level was not readable without racadm: virtual
console needs Enterprise; SOL is already enabled at 115.2 if you only have
Express.

Test from the Mac (LAN), before the timer fires:

```sh
curl -qk -o /dev/null -w '%{http_code}\n' https://192.168.1.182/
# log into the iDRAC UI as root with the password you just set
# optional: ipmitool -I lanplus -H 192.168.1.182 -U root -f <pwfile> chassis status
```

Then cancel the timer **before** you continue:

```sh
scripts/idrac-setup.sh --cancel
# equivalent: ssh tuns 'systemctl stop homelab-idrac-revert.timer'
```

If the Mac cannot reach it: wait for the revert, or `--cancel` and inspect
`ipmitool delloem lan get` / `lan get active` / `lan print 1` (read-only). Do
not enable the Proxmox firewall until iDRAC works, unless you explicitly accept
that a failed LAN+Tailscale pair means a trip to the machine.

### Optional SOL (separate owner step — not in the script)

No `console=` in the kernel cmdline, no `serial-getty@ttyS1`. Do this later,
not under the iDRAC NIC timer (it needs a reboot):

```sh
# on tuns, after iDRAC is proven and its revert timer is canceled
# GRUB_CMDLINE_LINUX extra: console=tty0 console=ttyS1,115200n8
# update-grub
systemctl enable --now serial-getty@ttyS1
# reboot at a time you choose
# then: ipmitool -I lanplus -H 192.168.1.182 -U root sol activate
```

## 2. Stage the Proxmox firewall (only after step 1 passed)

Record auto-detect (already `192.168.1.0/24`):

```sh
ssh tuns 'pve-firewall localnet'
```

Both `pve-firewall` (iptables) and `proxmox-firewall` (nftables) systemd units
are enabled. `host.fw` has **no** `nftables: 1`, `nft list tables` is empty, so
enabling `cluster.fw` is the **iptables** path. The script writes `nftables: 0`
explicitly and does not stop the nftables daemon (it is not compiling guest
rules today). Switching `nftables: 1` is a tech preview and would require
restarting every VM — out of scope.

11 VMs have `firewall=1` on net0 (template, templates, sectools, gateway, gitea,
pbs, nexus, sonarqube, jenkins, ci-agent, debian13-template). None have a
`/etc/pve/firewall/<vmid>.fw`. VM OPTIONS `enable` defaults to **0**, and PVE
requires that flag **in addition** to the NIC bit, so guest policy does not
flip when the datacenter firewall turns on. The `fwbr*` interfaces already
exist as plumbing.

Stale `10.2.6.0/24` SSH/UI allows in the current `cluster.fw` / `host.fw` are
replaced.

### 2a. Rules loaded, input ACCEPT

```sh
scripts/pve-firewall-stage.sh --policy=ACCEPT
```

Backup of the original files is kept at `/root/homelab-pve-fw-backup/` and is
**not** overwritten on the DROP pass. Timer `homelab-pve-fw-revert.timer`
restores those originals and runs `pve-firewall stop`.

Test, still inside 15 minutes:

- Mac: `ssh tuns true` and browser `https://proxmox.home.arpa:8006/`
- Tailscale: `ssh root@homelab-breakglass true` and `https://homelab-breakglass:8006/`
- VMs: `scripts/route-smoke.sh 192.168.1.240` (should match the last baseline)

Cancel if those fail and you need more than 15 minutes, fix, re-run. If they
pass, cancel **or** go straight to DROP (DROP re-arms a new 15m timer; cancel
the ACCEPT timer first):

```sh
scripts/pve-firewall-stage.sh --cancel
scripts/pve-firewall-stage.sh --policy=DROP
```

### 2b. Input DROP

Same tests as 2a, plus the negative proof **from sectools** (not from the Mac):

```sh
ssh tunsadmin@192.168.1.95 'ssh -o ConnectTimeout=5 -o BatchMode=yes root@192.168.1.181 true'
# expect: timeout / no route / connection refused — not a host-key prompt
ssh tunsadmin@192.168.1.95 'curl -qk -m 5 -o /dev/null -w "%{http_code}\n" https://192.168.1.181:8006/'
# expect: fail (empty code / 000), not 200/401/5xx from pveproxy
```

When Mac + Tailscale still work and sectools fails, cancel the timer:

```sh
scripts/pve-firewall-stage.sh --cancel
```

## 3. Rollback

| Layer | Command |
|---|---|
| iDRAC, timer still running | wait, or `scripts/idrac-setup.sh --cancel` then set dedicated + old IP by hand |
| iDRAC, after cancel | `ssh tuns "ipmitool delloem lan set dedicated; ipmitool lan set 1 ipaddr 10.2.6.180; ipmitool lan set 1 netmask 255.248.0.0; ipmitool lan set 1 defgw ipaddr 10.2.0.1"` |
| Firewall, timer still running | wait, or `--cancel` then `ssh tuns 'cp -a /root/homelab-pve-fw-backup/cluster.fw /etc/pve/firewall/cluster.fw; cp -a /root/homelab-pve-fw-backup/host.fw /etc/pve/nodes/tuns/host.fw; pve-firewall stop'` |
| Firewall, after cancel | same `cp` + `pve-firewall stop`, or set `enable: 0` in `cluster.fw` |

`pve-firewall compile` is useful **on tuns** after the files are in `/etc/pve`.
It has no offline/root flag (PVE 9.1.2 man page). Do not pipe Mac-side temp
files into it and assume they were what the node compiled.

## 4. What this does not do

- Does not install `racadm` or claim an iDRAC Enterprise licence.
- Does not change GRUB / serial-getty.
- Does not enable `nftables: 1` / take over with `proxmox-firewall`.
- Does not open 8006/22 to `192.168.1.0/24`.
- Does not push or Argo-sync anything; these files live on the hypervisor.
