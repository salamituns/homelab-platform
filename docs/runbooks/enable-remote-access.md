# Runbook: enable remote access (Tailscale subnet router on `gateway`)

Design: [ADR 0002](../adr/0002-remote-access-tailscale-subnet-router.md). Must start on the **home LAN**.
Do the 2026-10-24 incident remediation first (see `docs/postmortems/`): adding a new way into the
lab while a known-exposed key is still trusted would widen the hole.

## 1. Tailnet: policy first, then the key

1. Start the Tailscale app on the Mac and log in (this makes the Mac a tailnet member).
2. Admin console, **Access controls**: replace the policy with `tailscale/policy.hujson` and save.
   The `tests` block must pass, or the console refuses the save. Do this BEFORE step 3:
   a tag can only be put on an auth key once the policy defines who owns it.
3. Admin console, **Settings, Keys, Generate auth key**:
   - Reusable: **off** (one device, one key)
   - Expiration: **1 day**
   - Ephemeral: **off** (the gateway must survive reboots)
   - Pre-approved: **on**
   - Tags: **`tag:homelab-gateway`**
4. Put it in `.envrc` (never paste it into chat or a file in git):
   ```sh
   cd ~/homelab-platform && echo 'export TS_AUTHKEY="tskey-auth-..."' >> .envrc
   ```

## 2. Build `gateway`

```sh
cd ~/homelab-platform && source .envrc
ping -c1 -W1 192.168.1.96 && echo "STOP: .96 is in use" || echo ".96 free"
make plan                      # expect: 1 to add (gateway), 0 to change, 0 to destroy
make apply
scripts/trust-host-key.sh 192.168.1.96 121
```

## 3. Harden and enroll

```sh
cd ansible
ansible-playbook playbooks/gateway.yml --limit gateway --check --diff   # dry run
ansible-playbook playbooks/gateway.yml --limit gateway                  # baseline + tailscale
ansible-playbook playbooks/gateway.yml --limit gateway                  # again: tailscale tasks ok
```

Then delete the `TS_AUTHKEY` line from `.envrc`. It is single-use and already spent.

## 4. Verify

In the admin console, `homelab-gateway` shows tag `tag:homelab-gateway`, key expiry **disabled**,
and route `192.168.1.0/24` **approved** (by `autoApprovers`, no click needed).

```sh
ssh tunsadmin@192.168.1.96 'tailscale status; sysctl net.ipv4.ip_forward'
ssh tunsadmin@192.168.1.96 'ps -eo args | grep -c "[t]skey-auth"'    # expect 0: key never in argv
```

**The real test, from outside**: switch the Mac to the phone hotspot, then:

```sh
ssh Master 'kubectl get nodes'
curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.1.181:8006/    # expect 200
traceroute -n -m 3 192.168.1.90      # first hop should be a 100.x Tailscale address
```

Back on home Wi-Fi, check the Mac still talks to the LAN directly:

```sh
traceroute -n -m 3 192.168.1.90      # expect a direct hop, not 100.x
```

## If something goes wrong

Finally, lock in the "gateway cannot reach the laptop" property as a policy test: copy the Mac's
`100.x` address from the admin console (Machines), uncomment the last test in
`tailscale/policy.hujson` with that IP, paste the policy again, and commit.

| Symptom | Cause | Fix |
|---|---|---|
| `unknown user or host: "autogroup:member"` on save | Policy tests need a specific user, group, tag or host as `src` | Fixed in the repo: tests use `tag:homelab-gateway` as `src` |
| Auth key form will not accept the tag | Policy not saved yet | Step 1.2 first |
| `TS_AUTHKEY ... is empty` assertion | Forgot `source .envrc` | `source ../.envrc` |
| Route shows "awaiting approval" | Policy `autoApprovers` missing or tag wrong | Check policy; or approve once by hand |
| Reachable from hotspot but not at home | Mac routing LAN traffic through the tailnet | Tailscale app, untick "Use Tailscale subnets" at home |
| Gateway compromised | | Admin console: remove the device. Its node key dies; the LAN stays reachable at home |
