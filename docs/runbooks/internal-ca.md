# Internal CA and TLS on the gateway

How the lab CA of ADR 0015 section B is created, loaded and trusted, and how it is rolled back
or renewed. The cluster side (cert-manager, ClusterIssuer `lab-ca`, the wildcard Certificate
`*.apps.home.arpa`, the Gateway HTTPS listener, the redirects and the renamed routes) is all in
git: `k8s/platform/cert-manager/`, `k8s/platform/nginx-gateway/gateway.yaml` and the
`*-httproute.yaml` / `*-redirect.yaml` files. This runbook is the owner side, in order.

Custody rule throughout: the root and intermediate private keys live only in `private/ca/`
(gitignored) and in the owner's offline backup, exactly like the OpenBao unseal shares. They are
never printed, never on a command line, never in the repo. The root certificate alone is public
and is vendored at `ansible/files/ca/lab-root.crt`.

## 1. Prerequisites

The week 6 TLS PRs are merged and Argo CD has synced the `cert-manager` app (chart v1.21.3, CRDs
from the chart). Until the intermediate Secret exists, the `lab-ca` ClusterIssuer shows NotReady
and the wildcard Certificate stays pending; that is expected, nothing serves TLS yet, and the
`:80` listener keeps answering exactly as before.

## 2. Create the root and intermediate (Mac, offline)

```sh
scripts/ca-create-root.sh --dry-run   # the plan and commands; nothing is created
scripts/ca-create-root.sh
```

It creates the name-constrained (permitted `DNS:home.arpa`) ECDSA P-256 root (10 years,
pathlen:1) and intermediate (5 years, pathlen:0), refuses to overwrite anything, checks that
`private/ca/` is gitignored before writing a single byte, and prints only subject, notAfter and
fingerprint. It also vendors the public root to `ansible/files/ca/lab-root.crt`.

Record the dates now (renewal section below): root created `2026-11-02` (expires 2036-10-30), intermediate created
`2026-11-02` (expires 2031-11-01; the cluster wildcard expires 2027-01-31 and auto-renews).

Back up `private/ca/` the same place the OpenBao unseal shares are backed up, offline.

## 3. Load the intermediate into the cluster

```sh
scripts/ca-load-intermediate.sh --dry-run   # shows metadata and the ssh command, sends nothing
scripts/ca-load-intermediate.sh
```

The intermediate certificate and key are piped over the admin SSH path (`Master`, the same
convention as `scripts/k8s-issue-access-cert.sh`) as stdin to
`sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -`, creating the Secret
`cert-manager/lab-ca-intermediate`. Never use `!` in an agent session for this step.

Then check, from the same admin path:

```sh
ssh Master 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get clusterissuer lab-ca -o wide'
# expect Ready; then the wildcard Certificate *.apps.home.arpa issues (90 days, auto-renewed)
```

## 4. Trust the root on the Mac

```sh
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \
  ansible/files/ca/lab-root.crt
```

Undo: `sudo security remove-trusted-cert -d ansible/files/ca/lab-root.crt`. Browsers follow the
system store after a restart.

The VMs do not get the lab root yet: `lab_ca_trust` still distributes the per-host Caddy roots
(`-caddy-root.crt` suffix). Migrating the VM services to the lab CA is ADR 0015 owner decision 5,
deliberately later.

## 5. Verify

```sh
curl -q --cacert ansible/files/ca/lab-root.crt --resolve argocd.apps.home.arpa:443:192.168.1.240 \
  https://argocd.apps.home.arpa/        # expect a redirect/answer, not a certificate error
scripts/route-smoke.sh 192.168.1.240    # 20 checks: https codes + the http->https redirect per host
```

`route-smoke.sh` verifies every host against the vendored root, so it doubles as the
cert-manager proof. The two belleshop hosts only answer once the belleshop-deploy route rename
(the same change as this repo's, in that repo) is merged and synced.

## 6. Rollback

Every piece is separately reversible (ADR 0015 section F):

| Piece | Undo |
|---|---|
| HTTPS listener, redirects, renamed hosts | Revert the PR; DNS is unchanged, the `*.apps.home.arpa` wildcard and the old records both resolve to .240, so `*.local` works again immediately |
| Wildcard Certificate, ClusterIssuer, cert-manager app | Revert the PR / delete the app in Argo CD |
| Intermediate Secret | `ssh Master 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n cert-manager delete secret lab-ca-intermediate'` |
| Mac trust | `sudo security remove-trusted-cert -d ansible/files/ca/lab-root.crt` |
| Keys and certs on the Mac | See Undo in the `scripts/ca-create-root.sh` header |

## 7. Renewal

| Tier | Lifetime | Renewal |
|---|---|---|
| Root | 10 years | Owner: generate a new root (deliberate act; the script refuses while the old one is vendored), re-sign the intermediate, redistribute the cert, re-trust. Calendar long before the notAfter recorded in section 2 |
| Intermediate | 5 years | Owner: new intermediate from the same root, re-run `scripts/ca-load-intermediate.sh`, cert-manager reissues every leaf; clients unchanged (they trust the root). Calendar at 4 years |
| Leaf (`*.apps.home.arpa` and later leafs) | 90 days | Automatic: cert-manager renews at 30 days left; nothing to do. The `cert-manager.io` alerts in the stack cover failures |

## 8. What is deliberately not here

MySQL TLS for the `mysql-bao` path (ADR 0014 step 6) is a named follow-up, not this rollout:
it needs MySQL configuration and a restart. The Proxmox UI certificate is its own owner step
(CSR on `tuns`, signed with this root) and lives in the Proxmox firewall/cert runbooks.
