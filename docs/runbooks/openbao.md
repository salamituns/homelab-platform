# Runbook: OpenBao on sectools (`bao.home.arpa`)

Why and what: [ADR 0014](../adr/0014-secrets-and-identity.md). OpenBao runs on `sectools` on
`127.0.0.1:8200` (Raft storage in `/var/lib/openbao`), behind Caddy TLS at `https://bao.home.arpa`.
The Ansible role never inits, unseals or stores any key or token. Everything below runs in your
terminal, and nothing it prints belongs in the repo, in a variable or in a log.

You need the `bao` CLI locally (`brew install openbao`) and the sectools Caddy root CA:
`ansible/files/ca/sectools-caddy-root.crt` (already fetched by the Caddy role).

```sh
export BAO_ADDR=https://bao.home.arpa
export BAO_CACERT=ansible/files/ca/sectools-caddy-root.crt
```

## 1. Deploy (once)

```bash
cd ansible
ansible-playbook playbooks/openbao.yml --limit sectools --check --diff
ansible-playbook playbooks/openbao.yml --limit sectools
ansible-playbook playbooks/dns.yml --limit gateway   # publishes bao.home.arpa
```

A restart seals the store (no auto-unseal, ADR 0014), so any later playbook run that changes the
config, unit or version leaves OpenBao sealed until you run step 3 again. Expect that; it is not
an outage the playbook caused silently.

The role also turns swap off on sectools: mlock is off, so a swapped-out page could otherwise
carry secrets to the disk PBS copies nightly. `swapon --show` should print nothing afterwards.

## 2. Initialise (your terminal, once)

```sh
bao operator init -key-shares=3 -key-threshold=2
```

This prints three **unseal shares**, the threshold, and the **initial root token**. Store them
somewhere that is neither the Proxmox disk array (PBS copies it nightly, and a backup is useless
without the shares anyway) nor this repo. A password manager or paper in a safe works. Two shares
unseal the store; losing two shares loses everything in it, snapshots included.
Verified live 2026-11-03: `GET /v1/sys/seal-status` on sectools reports `"n": 3, "t": 2`.

## 3. Tell if it is sealed (and unseal after a reboot)

OpenBao starts sealed after every reboot on purpose. Nothing is wrong; the cluster keeps running
on secrets already synced.

```sh
bao status                                            # "Sealed: true" means it needs two shares
curl -q -s -o /dev/null -w '%{http_code}\n' $BAO_ADDR/v1/sys/health
# 200 = unsealed, 501 = not initialised, 503 = sealed
bao operator unseal              # paste a share, then a second, different one
```

## 4. Audit log (comes with the deploy, verify here)

The audit device is declared in `openbao.hcl`, because OpenBao 2.7.2 refuses to enable audit
devices over the API (tested 2026-10-31). After init it logs every request and response with
HMAC-hashed values, never clear secrets:

```sh
bao audit list                   # shows file/
tail -1 /var/log/openbao/audit.log
```

`logrotate` moves the file weekly (`/etc/logrotate.d/openbao`, 8 kept) and sends SIGHUP, which
reopens the file without sealing the store. OpenBao fails closed: if the audit log cannot be
written, requests are denied, so a full disk here is an outage — monitoring covers disk space.

## 5. Raft snapshots

A snapshot is only useful together with the unseal shares, so it may live on the Mac:

```sh
mkdir -p ~/backups
bao operator raft snapshot save ~/backups/bao-$(date +%F).snap
```

Restore is a last resort. Unlike the old mental model, it does not touch the data directory by
hand: `restore` talks to the running, unsealed server and installs the snapshot into Raft. You
need a token that may restore (the root token, or a policy with `update` on
`sys/storage/raft/snapshot/restore`):

```sh
bao operator raft snapshot restore ~/backups/bao-2026-11-01.snap
# If the current cluster was re-initialised after the snapshot, the unseal keys no longer match
# the snapshot's data; -force skips that consistency check:
bao operator raft snapshot restore -force ~/backups/bao-2026-11-01.snap
```

After the restore, unseal with the shares that were current **when the snapshot was taken**: the
snapshot brings its own encrypted master key, so the shares from any later init stop working.

## 6. Revoke the root token (last)

Once the audit log is on, the ESO role and policies exist (ADR 0014 steps 3-4) and the proof has
passed, the root token has no remaining job. Revoke it so it cannot leak out of your password
manager. **Revoked 2026-11-02**, just before the week-5 closeout was pushed.

```sh
read -rs BAO_TOKEN; export BAO_TOKEN    # load the token; read the safety note below first
bao token revoke -self
```

**Loading a token safely.** Use `read -rs BAO_TOKEN; export BAO_TOKEN` as a line of its own: if
it sits inside a multi-line pasted block, `read` consumes the next pasted line and the paste
breaks apart. Root tokens start with `s.`; a 44-character base64 value is an unseal share or a
key, not a token.

If root access is needed later, mint a short-lived root token with
`scripts/openbao-breakglass.sh` - one command, the shares only at hidden prompts, the
token minted, used and revoked ON sectools (it never reaches the Mac or any terminal
output). Two subcommands:

```sh
scripts/openbao-breakglass.sh apply-config    # ONCE per config change; see below
scripts/openbao-breakglass.sh root-run <cmd>  # mint, run the command, revoke (always)
scripts/openbao-breakglass.sh root-run alertmanager   # the step-5 alert setup (ADR 0015 D)
scripts/openbao-breakglass.sh root-run watchdog-url   # PATCH watchdog_url only (keep SMTP)
scripts/openbao-breakglass.sh root-run cloudflared-token  # tunnel token for edge-public (ADR 0019 D7)
scripts/openbao-breakglass.sh root-run -- bao auth list   # anything else, same pattern
```

`root-run` needs `apply-config` to have run once (2026-11-03: OpenBao >= 2.5.3 defaults
`disable_unauthed_generate_root_endpoints` to true, which blocks generate-root on the
listener; the role sets it false - `openbao_disable_generate_root_endpoints`, role
openbao). Two facts decide the shape of this flow, both verified against a real 2.7.2
server (scripts/openbao-breakglass-test.sh):

- **The bao CLI cannot do it.** Its generate-root subcommands (`-generate-otp`, `-init`,
  even `-decode`) call the LEGACY `/v1/sys/generate-root-token/*` endpoints, which the
  2.7.2 server gates unconditionally - 403 even with the listener flag false. The
  script speaks the NEW API instead (`/v1/sys/generate-root/attempt` + `/update`) and
  decodes client-side (unpadded-base64 XOR with the OTP). That is also why the old
  section-6 commands below no longer worked.
- **The listener flag does not reload on SIGHUP** (only TLS files and audit do), so
  applying the config change restarts openbao and the store comes back SEALED.
  `apply-config` handles the whole sequence: it prints and runs the playbook
  (`--check --diff` first), then unseals by prompting for shares (hidden) and piping
  them to `PUT /v1/sys/unseal` over ssh stdin - the bao CLI refuses piped unseal input,
  so the API it is. It stops as soon as the store reports unsealed, whatever the
  threshold.

The design keeps root generation sectools-only: the flag is false on the 127.0.0.1
listener, and Caddy answers 403 for `/v1/sys/generate-root*`, `/v1/sys/generate-root-token*`
and `/v1/sys/rekey*` from the network (host_vars/sectools.yml, `blocked_paths`), so
`bao.home.arpa` is never a root-generation door. Rekey stays blocked everywhere: its
listener flag (`disable_unauthed_rekey_endpoints`, default true since 2.5.0) is
untouched.

The script always revokes the token when the command is done - and verifies the
revocation; a trap revokes again on any failure. `root-run` cancels any in-flight
generation before it starts, so a failed run can simply be re-run. If you ever need the
manual dance instead (the old flow, kept for reference), it is the API the script uses:
init an attempt with an OTP, submit 2 shares (the threshold; the store holds 3
shares with a threshold of 2, verified live 2026-11-03) to the update endpoint, decode
the encoded token with the OTP - but the script does exactly that without putting the
token in a terminal.

Read-only: list existing tokens by accessor, then look one up without ever printing a
token value:

```sh
bao list auth/token/accessors
bao token lookup -accessor <accessor>   # policies, display name, TTL; no token value
```

## ESO on the cluster (ADR 0014 step 3)

1. Platform repo (all in git, nothing hand-applied):
   - Argo app `external-secrets` (chart 2.14.0, one replica, ServerSideApply) installs ESO in namespace
     `external-secrets`; the CRDs come with the chart.
   - `cluster-config/eso-tokenreview.yaml` binds `system:auth-delegator` to ServiceAccount `dev/eso-belleshop`
     (the ServiceAccount itself lives in belleshop-deploy), so OpenBao verifies ESO's JWT through TokenReview
     with no stored reviewer token.
   - The 443 rule on sectools names the three k8s nodes: ESO pods appear as node IPs after SNAT. Caddy keeps
     `s3.home.arpa` admin-only (`allowed_clients` on the site), so the nodes reach the port but not the
     Terraform state.
2. OpenBao (your terminal; secrets stay out of the repo):
   ```sh
   scripts/openbao-setup-belleshop.sh   # kv-v2 at secret/, kubernetes auth, policy, role, secrets
   ```
   It skips what already exists, loads `private/belleshop-secrets.env` over stdin, and prints statuses, never
   values. `--overwrite` replaces the secrets only when you mean it.
3. belleshop-deploy: ServiceAccount `eso-belleshop`, `SecretStore` (carrying the sectools Caddy root CA) and an
   `ExternalSecret` for `secret/belleshop/app`. Step 3 ends when the synced Secret equals today's
   `belleshop-secrets` and nothing changed for the app.

## MySQL rotation (ADR 0014 step 4)

In git first: the `mysql-bao` LoadBalancer Service in belleshop-deploy (`.244`, sectools only) and the ESO objects
that read `database/static-creds/belleshop` into a second shadow Secret, `dev/belleshop-db-eso`. Nothing consumes
that Secret yet; the app switch is step 5.

Three controls on the `.244` path, all verified on the cluster 2026-10-31 with a throwaway MySQL behind a `.245`
LoadBalancer:

- `loadBalancerSourceRanges: 192.168.1.95/32` is enforced by kube-proxy (iptables mode) at the LoadBalancer
  address: a client outside the range (tested from the Mac) cannot connect to the LB IP.
- `allocateLoadBalancerNodePorts: false` is mandatory here. With node ports allocated (the default), every node
  also answers on a high port for ANY source, which bypasses the range entirely. Verified: the blocked client
  connected through `nodeIP:nodePort` on all three nodes, and stopped once the Service was recreated without
  node ports.
- MySQL never sees `192.168.1.95`: kube-proxy masquerades the traffic to the receiving node's own address in its
  Flannel pod subnet (kube-flannel-ds gives each node a /24 out of 10.244.0.0/16; observed `10.244.3.1`). The
  OpenBao account is therefore `bao-admin@'10.244.%'`, not the `192.168.1.%` first sketched.

Two phases, because the static role starts a clock:

```sh
scripts/openbao-setup-mysql-rotation.sh                     # phase 1: account, connection, rotate-root, policy
scripts/openbao-setup-mysql-rotation.sh --create-static-role  # phase 2: only when the app reads the file mount
```

Both are idempotent and need `kubectl`; the root password comes from `private/belleshop-secrets.env` over stdin
(never printed, never on any command line). Phase 1 creates the `bao-admin` MySQL account (REQUIRE SSL, global
`CREATE USER` only), enables `database/`, configures the connection to `.244`, rotates that root credential (only
OpenBao knows the password afterwards) and writes the `belleshop-read` policy with both paths. Phase 1 alone
changes nothing for the app: no clock runs.

Phase 2 (`--create-static-role`) rotates the app password **immediately** and starts the 24h clock:

- The old password keeps working only until the NEXT rotation. Running pods and the hand-made
  `belleshop-secrets` still hold the old password, so an app that still reads the environment variable breaks
  24h after phase 2 — and restarting pods does not help, they restart with the same old value.
- Reading `static-creds` never triggers a rotation; that is all ESO does, once a minute.
- `rotate-root` needs `root_rotation_statements` here: the plugin default targets `'{{username}}'@'%'`, which
  fails with MySQL error 1396 for the host-scoped account. REQUIRE SSL survives the rotation with no extra
  statement (`ssl_type=ANY`; the script asserts it and fails loudly otherwise).

Order for step 5 (the catch-22 and its answer): the generator cannot read `static-creds` before the role exists,
and the role cannot exist before its first rotation, so `belleshop-db-eso` can never be ready before the first
rotation. It does not need to be: with the Secret volume mounted `optional: true`, a pod starts while the Secret
is absent, and the app falls back to the environment variable, which RETAIN CURRENT PASSWORD keeps valid for the
whole first 24h. When the Secret appears, kubelet materialises the file into the running pod's mount (verified
2026-10-31 in a throwaway namespace: pod started with an empty mount, the file appeared after the Secret was
created, no restart), and the app picks the new password up on its next connection. No rollout is needed.

1. Deploy the app version that reads the mounted file when present and falls back to `MYSQL_PASSWORD` when not,
   with the `belleshop-db-eso` volume marked `optional: true`. Pods must start and serve on the env password
   (today's behaviour, unchanged).
2. Run phase 1. Nothing changes for the app; check the statuses and the negative test below.
3. Run phase 2. The clock starts; ESO syncs `belleshop-db-eso` within ~1m and kubelet delivers the file to the
   running pods.
4. Before 24h pass, confirm the backend uses the file password (a probe plus `bao write -f
   database/rotate-role/belleshop` is the full step-6 proof). After that, `MYSQL_PASSWORD` in the hand-made
   `belleshop-secrets` is dead weight for the backend; the other keys stay as they are.
   Done 2026-11-01/02: `MYSQL_PASSWORD` was removed from the hand-made `belleshop-secrets`; the
   other keys stayed.

Check afterwards (no values printed):

```sh
kubectl -n dev get secret belleshop-db-eso -o jsonpath='{.data}' | jq -r 'keys'   # MYSQL_PASSWORD, MYSQL_USER
nc -z 192.168.1.244 3306 && echo REACHED   # from a host that is NOT sectools: this must fail
bao write -f database/rotate-role/belleshop # manual rotation, what the 24h schedule runs (step 6 uses it)
```

If a run fails part-way:

- Before phase 2, nothing is time-critical: fix and re-run, the script skips what exists.
- During or after phase 2 the clock is running. First try to complete rather than undo: re-run with
  `--create-static-role` (idempotent) and verify the Secret and the file mount as above. To abort instead:
  `bao delete database/static-roles/belleshop` stops further rotations; the app password stays at whatever
  OpenBao last set, so set one you know by hand (`ALTER USER 'belleshop'@'%' IDENTIFIED BY '...'`), put it in
  the hand-made Secret, and re-create the role later only after the app reads the file.

Undo (also in the script header):

```sh
bao delete database/static-roles/belleshop   # if the static role exists
bao secrets disable database/
kubectl -n dev exec -it mysql-0 -- mysql -uroot -p   # DROP USER 'bao-admin'@'10.244.%';
                                                      # ALTER USER 'belleshop'@'%' IDENTIFIED BY '...';
scripts/openbao-setup-belleshop.sh                   # rewrites the same two-path policy
```
