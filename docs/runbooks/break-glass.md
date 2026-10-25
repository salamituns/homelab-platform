# Runbook: break-glass access (Tailscale on `tuns`)

Design: [ADR 0003](../adr/0003-break-glass-access.md). Setup must start on the **home LAN**.

## Setup (once)

1. The break-glass grant and test are in `tailscale/policy.hujson`. Paste the policy
   into the admin console, **Access controls**, and save. Tests must pass.
2. Admin console, **Settings, Keys, Generate auth key**: reusable **off**, expiry **1 day**,
   ephemeral **off**, pre-approved **on**, tag **`tag:homelab-breakglass`**.
3. Enroll:
   ```sh
   cd ~/homelab-platform && echo 'export TS_AUTHKEY="tskey-auth-..."' >> .envrc && source .envrc
   cd ansible
   ansible-playbook playbooks/breakglass.yml --limit tuns --check --diff
   ansible-playbook playbooks/breakglass.yml --limit tuns
   ansible-playbook playbooks/breakglass.yml --limit tuns     # again: changed=0 expected
   sed -i '' '/TS_AUTHKEY/d' ../.envrc                          # key is spent
   ```
4. Check on `tuns`: forwarding still off, no routes advertised.
   ```sh
   ssh tuns 'sysctl -n net.ipv4.ip_forward; tailscale status --self --peers=false'   # expect 0
   ```

## Use it (gateway is down)

From anywhere on Tailscale, use the hypervisor's tailnet name instead of its LAN IP:

```sh
ssh root@homelab-breakglass                                       # the hypervisor
ssh -J root@homelab-breakglass tunsadmin@192.168.1.90             # any VM, via the hypervisor
open https://homelab-breakglass:8006/                             # Proxmox UI: VM consoles
ssh root@homelab-breakglass 'qm status 121; qm start 121'         # bring the gateway back
```

`-J` (ProxyJump) only forwards a TCP connection through `tuns`. Your Mac does the SSH
authentication to the VM with its own key; no key is stored on or used from the hypervisor.

## Drill (do it now, then every few months)

On the phone hotspot:

```sh
ssh root@homelab-breakglass 'qm shutdown 121'           # take the front door away
ssh Master 'kubectl get nodes'                          # expect: fails (no route)
ssh -J root@homelab-breakglass tunsadmin@192.168.1.90 'kubectl get nodes'   # expect: works
ssh root@homelab-breakglass 'qm start 121'              # restore
sleep 60; ssh Master 'kubectl get nodes'                # expect: works again via gateway
```

## If something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `homelab-breakglass` does not resolve | MagicDNS off on the Mac | Tailscale app, enable "Use Tailscale DNS", or use the node's `100.x` IP |
| Connection times out on a port | Grant does not include that port | Intended. Add the port to the grant only if repair needs it |
| `tuns` shows `ip_forward = 1` | Role ran with routes set | Check `host_vars/tuns.yml` has `tailscale_advertise_routes: []` |
| Break-glass node compromised or lost | | Admin console: remove the device. LAN access at home is unaffected |
