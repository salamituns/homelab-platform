# Runbook: Lynis on the Kubernetes nodes

Lynis 3.0.9-1 (Ubuntu distro package) runs a nightly host audit on Master,
WorkerNode1, and WorkerNode2. Ansible role `lynis` (`ansible/playbooks/lynis.yml`)
pins and holds that package, shifts the timer, and exports the last report as
Prometheus metrics. It does **not** change `lynis.service` `ExecStart`.

## What it is

- Packaged unit: `ExecStart=/usr/sbin/lynis audit system --cronjob` (dash under
  PID 1). Falco only exempts that exact launch
  (`k8s/platform/falco/values.yaml`, `#83`/`#85`). Hand-run Lynis still pages.
- Timer drop-in: `23:30` America/Chicago plus `RandomizedDelaySec=900`, so the
  audit finishes before the etcd snapshot at `00:45` America/Chicago and before
  PBS `01:30–02:30`. Packaged default was `OnCalendar=daily` + 30m jitter
  (~00:00–00:30), which can overlap 00:45.
- After a successful audit, `OnSuccess=lynis-textfile.service` parses
  `/var/log/lynis-report.dat` into `/var/lib/node_exporter/textfile/lynis.prom`.
  No custom.prf skips: the score stays whatever the host earned.

Live baseline 7 Nov 2026 on Master: `hardening_index=64`, 1 warning
(`PKGS-7392`), 44 suggestions. Expect `LynisWarningsPresent` in the UI after 1d
until that package warning is actually fixed.

## Schedule and Falco

Do not edit `ExecStart`, the binary path, or how systemd starts Lynis. Post-processing
is a separate unit on purpose. If Lynis Falco events return, check `proc.ppid` /
cmdline first (`docs/runbooks/falco-alerts.md`).

## How to read suggestions

```sh
ssh Master 'sudo -n grep "^suggestion\\[\\]=" /var/log/lynis-report.dat'
ssh Master 'sudo -n grep "^warning\\[\\]=" /var/log/lynis-report.dat'
ssh Master 'sudo -n grep "^hardening_index=" /var/log/lynis-report.dat'
```

Grafana dashboard **Lynis** (folder Homelab) graphs `lynis_hardening_index` per
node. Prometheus: `lynis_hardening_index`, `lynis_warnings`,
`lynis_suggestions`, `lynis_report_timestamp_seconds`, `lynis_info`.

## How to raise the score (safely)

Change the **host** via Ansible (PAM, unattended upgrades, partitions, and so
on) so the next audit records a higher index. Do not add `skip-test` lines to
raise the number. A drop of 3 vs the 7-day max fires `LynisHardeningIndexDropped`.

## Owner apply

```sh
cd ansible
ansible-playbook playbooks/lynis.yml --check --diff
ansible-playbook playbooks/lynis.yml
```

Optional: export the current report without waiting for 23:30 (does not re-run
Lynis, so Falco stays quiet):

```sh
ssh Master 'sudo -n systemctl start lynis-textfile.service'
```

Re-running `lynis.service` is a full audit (Falco-exempt, noisy I/O). Prefer the
timer.

Rollback: revert the git commit, re-run the playbook, or remove
`/etc/systemd/system/lynis.timer.d/schedule.conf`,
`/etc/systemd/system/lynis.service.d/textfile.conf`,
`/etc/systemd/system/lynis-textfile.service` and `daemon-reload`. The packaged
timer returns to ~00:00–00:30. `apt-mark unhold lynis` only if you intend to
unpin.

## PKGS-7392 explained (7 Nov 2026)

Lynis asks Ubuntu's `/usr/lib/update-notifier/apt-check`, which simulates a **full dist-upgrade** and counts a package
as a security update when its candidate (or a version it masks) comes from `noble-security`. That includes **new**
packages the upgrade would pull in. On Master and WorkerNode1 the count of 1 was `libdrm-amdgpu1`: not installed,
required by a newer `fwupd`, candidate in `noble-security`. `unattended-upgrades` installs nothing in that case
(it only upgrades installed packages), so the warning never cleared on its own.

Find the package behind the count (same rules as apt-check, prints names):

```sh
ssh Master 'python3 -' < scripts/aptcheck-security-names.py
```

Fix used: `apt-get install --no-install-recommends libdrm-amdgpu1` (no reboot). Re-check without paging Falco by
starting the packaged unit, never `lynis` by hand: `sudo systemctl start lynis.service` (the exporter runs via
`OnSuccess=`). Result: hardening index 64 → 69 on both nodes, warnings 0.
