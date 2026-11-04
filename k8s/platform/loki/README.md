# Loki + Grafana Alloy (ADR 0017 PR 1)

Argo Application `loki` (`k8s/platform/apps/loki.yaml`), picked up by `platform-root`.

| Piece | Pin |
|---|---|
| Loki chart | grafana-community/loki `21.0.0` (OSS; `grafana/loki` 7.x is GEL-only) |
| Loki image | `grafana/loki:3.7.9@sha256:0db216b630ae1f348a1584c67f3cead8b4c1fc839169a39501db664744158e28` |
| Alloy chart | grafana/alloy `1.15.0` |
| Alloy image | `grafana/alloy:v1.21.3@sha256:8ab871206bd2d8f89277f53abffee5f452a293980788d52f85fa183a87a505a4` |

Runbook: `docs/runbooks/logs.md`.
