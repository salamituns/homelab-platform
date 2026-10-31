# Runbook: internal DNS (`*.home.arpa`)

Design: [ADR 0004](../adr/0004-internal-dns.md). Records: `ansible/inventory/group_vars/all/dns.yml`.

## 1. Server on `gateway`

```sh
cd ~/homelab-platform/ansible
ansible-playbook playbooks/dns.yml --limit gateway --check --diff
ansible-playbook playbooks/dns.yml --limit gateway
ansible-playbook playbooks/dns.yml --limit gateway        # again: changed=0

dig +short @192.168.1.96 proxmox.home.arpa                # 192.168.1.181
dig +short @192.168.1.96 argocd.apps.home.arpa            # 192.168.1.240 (wildcard, the Gateway's data plane)
dig @192.168.1.96 nothere.home.arpa | grep status         # NXDOMAIN (zone is authoritative)
dig +short @192.168.1.96 example.com                      # an IP (forwarded upstream)
ssh tunsadmin@192.168.1.96 'sudo ss -lunp | grep ":53 "'  # dnsmasq only on 192.168.1.96
```

## 2. Laptop: Tailscale split DNS

Admin console, **DNS**, **Nameservers, Add nameserver, Custom**:
- Nameserver: `192.168.1.96`
- **Restrict to domain** (split DNS): `home.arpa`

Make sure the Mac's Tailscale app has **Use Tailscale DNS settings** on. Then, at home and away:

```sh
dscacheutil -q host -a name proxmox.home.arpa     # macOS resolver path (dig bypasses it)
open https://proxmox.home.arpa:8006/
```

## 3. VM clients, one at a time

```sh
ansible-playbook playbooks/dns.yml --limit sectools --check --diff
ansible-playbook playbooks/dns.yml --limit sectools
ssh tunsadmin@192.168.1.95 'resolvectl query gitea.home.arpa; resolvectl query example.com'
ansible-playbook playbooks/dns.yml --limit managed        # the rest, serial: 1
ssh Master 'kubectl get nodes; kubectl -n kube-system get pods -l k8s-app=kube-dns'
```

## Add or change a record

Edit `dns.yml`, commit, then `ansible-playbook playbooks/dns.yml --limit gateway`.

## If something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `dig` works, browser does not (Mac) | macOS not using Tailscale DNS | Tailscale app: Use Tailscale DNS settings; check `scutil --dns \| grep -A3 home.arpa` |
| `dnsmasq: failed to create listening socket ... Address already in use` | Something else bound to 192.168.1.96:53 | `sudo ss -lunp \| grep :53` on gateway |
| `*.home.arpa` fails on a VM, internet names fine | Gateway down: by design only internal names break | Use IPs; restore gateway (break-glass runbook) |
| Internet names fail on a VM | Not caused by this role (routing-only domain) | `resolvectl status`; check the link's own DNS |
