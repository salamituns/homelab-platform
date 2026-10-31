# Role: openbao

OpenBao v2.7.2 on `sectools` as the lab secrets store. ADR 0014, runbook `docs/runbooks/openbao.md`.

- Binary: pinned release tarball, SHA-256 verified (upstream `checksums.txt` on the release page,
  checked 2026-10-31), unpacked to `/opt/openbao/<version>/bao`, linked from `/usr/local/bin/bao`.
- Listens on `127.0.0.1:8200` with TLS off. `https://bao.home.arpa` is Caddy on 443 (role: caddy);
  clients trust `ansible/files/ca/sectools-caddy-root.crt`.
- Raft storage in `/var/lib/openbao` (0700, single node). The audit device writes to
  `/var/log/openbao` and is enabled by the owner after init (runbook step 5).
- mlock stays on: OpenBao pins its memory so the sealed store never swaps to disk. The service
  unit grants `LimitMEMLOCK=infinity` instead of `CAP_IPC_LOCK`, so the capability set stays empty.
- The role installs and configures, nothing more. It never inits, unseals, or sees any key or
  token; the owner does all of that in their own terminal (runbook). Init and unseal output never
  belongs in this repo, in a variable or in a log.
- Sealed after every reboot is the design, not a fault: no auto-unseal until a safe key holder
  exists (ADR 0014 "Not now").
