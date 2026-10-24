# Runbook: destroy and rebuild a Terraform-managed VM

Use for: the week 1 proof, recovering a broken VM, or proving a change is reproducible.
Example target: `sectools` (VMID 120, 192.168.1.95). Expected time: about 6-8 minutes.

> Only for VMs in the Terraform `terraform` pool. Anything on the VM's disk is lost.
> `sectools` holds nothing yet, so it is safe to rebuild.

## 0. Start the clock and load credentials

```sh
cd ~/homelab-platform
source .envrc
date
```

## 1. Destroy

```sh
terraform -chdir=terraform/proxmox destroy -target='module.vm["sectools"]'
```

Read the plan: it must say `0 to add, 0 to change, 1 to destroy`, and the one VM must be `sectools`.
Type `yes`.

Check it is gone:

```sh
ssh tuns 'qm list | grep -w 120 || echo "120 is gone"'
```

## 2. Forget the old host key

The rebuilt VM gets a new SSH host key. Without this step SSH refuses to connect
(`REMOTE HOST IDENTIFICATION HAS CHANGED`). That warning is SSH doing its job.

```sh
ssh-keygen -R 192.168.1.95
```

## 3. Rebuild

```sh
make plan      # expect: 1 to add, 0 to change, 0 to destroy
make apply     # about 4 minutes
```

## 4. Verify and trust the new host key

```sh
IP=192.168.1.95; VMID=120
ssh-keyscan -t ed25519 $IP 2>/dev/null | grep -v '^#' | ssh-keygen -lf -
ssh tuns "qm guest exec $VMID -- cat /etc/ssh/ssh_host_ed25519_key.pub" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["out-data"].strip())' | ssh-keygen -lf -
```

The two `SHA256:...` fingerprints must match. If they do not, **stop**: something else is
answering on that IP. If they match:

```sh
ssh-keyscan -t ed25519 $IP 2>/dev/null | grep -v '^#' >> ~/.ssh/known_hosts
```

## 5. Wait for cloud-init

```sh
ssh tunsadmin@192.168.1.95 'cloud-init status --wait'    # expect: status: done
```

## 6. Harden

```sh
make baseline-check HOST=sectools    # dry run
make baseline HOST=sectools          # apply
make baseline HOST=sectools          # expect: changed=0
```

## 7. Verify

```sh
H=tunsadmin@192.168.1.95
ssh $H echo OK
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive $H true   # denied
ssh root@192.168.1.95 true                                                                       # denied
ssh $H 'sudo sshd -T | grep -iE "^(permitrootlogin|passwordauthentication|allowusers) "'
ssh $H 'systemctl is-active fail2ban chrony auditd qemu-guest-agent unattended-upgrades'
date
```

## 8. Record the result

Write the time taken and anything that surprised you in `docs/week-01.md` (section 10),
tick the proof box in `ROADMAP.md`, then commit:

```sh
git add -A && git commit -m "Week 1 proof: rebuilt sectools from code in N minutes"
```

## If something goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `401 authentication failure` | Forgot `source .envrc` | `source .envrc` |
| `permission check failed` | Token lacks a privilege, or VM not in pool | Check `pool_id` in the module; check ACLs with `ssh tuns pveum acl list` |
| Apply hangs past 10 min | Guest agent not starting | Proxmox UI, VM 120, Console: look at the boot |
| `Host key verification failed` | Step 2 or 4 skipped | `ssh-keygen -R 192.168.1.95`, then redo step 4 |
| Ansible apt lock errors | cloud-init still running | Step 5, then rerun |
| Locked out of SSH | Bad SSH change | Proxmox UI, VM 120, Console (does not use SSH) |
