# Role: openbao

OpenBao v2.7.2 on `sectools` as the lab secrets store. ADR 0014, runbook `docs/runbooks/openbao.md`.

- Binary: pinned release tarball, SHA-256 verified (upstream `checksums.txt` on the release page,
  checked 2026-10-31), unpacked to `/opt/openbao/<version>/bao`, linked from `/usr/local/bin/bao`.
- Listens on `127.0.0.1:8200` with TLS off. `https://bao.home.arpa` is Caddy on 443 (role: caddy);
  clients trust `ansible/files/ca/sectools-caddy-root.crt`.
- Break-glass root generation stays possible without a standing root token: the listener keeps
  `disable_unauthed_generate_root_endpoints = false` (`openbao_disable_generate_root_endpoints`,
  OpenBao >= 2.5.3 defaults it to true) - safe because the listener is loopback-only and Caddy 403s
  the generate-root/rekey paths from the network (runbook §6, `scripts/openbao-breakglass.sh`).
  The flag applies at startup only (no SIGHUP reload, verified 2026-11-03), so changing it
  restarts openbao and re-seals the store.
- Raft storage in `/var/lib/openbao` (0700, single node). The audit device is declared in the
  config file (OpenBao 2.7.2 refuses `bao audit enable` over the API, tested 2026-10-31), writes
  `/var/log/openbao/audit.log`, and is rotated weekly by `/etc/logrotate.d/openbao` (move + SIGHUP,
  which reopens the file without sealing the store).
- mlock is off on purpose: with Raft, bbolt memory-maps the whole database and mlock would pin it
  all in physical memory, risking the OOM killer on this 4 GB VM (OpenBao's mlock-removal RFC).
  A swapped-out page could otherwise carry secrets to the disk PBS copies nightly, so the role
  also turns swap off on sectools (`openbao_disable_swap`; safe: 524 K of swap ever touched).
- The role installs and configures, nothing more. It never inits, unseals, or sees any key or
  token; the owner does all of that in their own terminal (runbook). Init and unseal output never
  belongs in this repo, in a variable or in a log.
- Sealed after every reboot is the design, not a fault: no auto-unseal until a safe key holder
  exists (ADR 0014 "Not now").
