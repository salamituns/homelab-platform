# CI gates (`ci/gates/`)

One definition of "safe to ship" (ADR 0011). Pipelines call these scripts; they
must not re-implement or wrap them with `|| true`. Ansible copies `*.sh` to
`/opt/ci-gates/` on the build agent (root:root, 0755).

Exit 0 = pass. Non-zero = fail the build. Reports go to `$REPORT_DIR`
(default `./reports`).

## Commands

| Script | Argument | Fails when | Reports |
|---|---|---|---|
| `secrets.sh` | git repo directory | any gitleaks finding | `secrets.sarif`, `secrets.json` |
| `deps.sh` | source directory | HIGH/CRITICAL vuln **with a fix**; HIGH/CRITICAL misconfig | `deps.json` (all severities) |
| `image.sh` | image ref | HIGH/CRITICAL vuln **with a fix** | `image.json` (all severities) |
| `sbom.sh` | image ref | syft error | `sbom.spdx.json` |
| `sign.sh` | `registry/repo@sha256:…` | missing digest; missing `COSIGN_*`; missing SBOM; cosign error | none (signature is on the registry) |

`deps.sh` / `image.sh` run Trivy **twice**: JSON with `--exit-code 0` (the
archive) then `--severity HIGH,CRITICAL --ignore-unfixed --exit-code 1` (the
gate). Two runs so the fail rule stays in Trivy instead of a jq rewrite of
`FixedVersion`.

Cache: `$TRIVY_CACHE_DIR` or `$HOME/.cache/trivy`. DB download is allowed.
Trivy is invoked with `--config /dev/null` and an explicit `--ignorefile` so a
`trivy.yaml` / `.trivyignore` in the caller's cwd cannot weaken the gate (or
fail the agent user with permission errors).

## How a pipeline calls them

```sh
export REPORT_DIR="${WORKSPACE}/reports"
/opt/ci-gates/secrets.sh "${WORKSPACE}"
/opt/ci-gates/deps.sh "${WORKSPACE}"
# build image, tag as registry.home.arpa/belleshop/<name>:<gitsha>
/opt/ci-gates/image.sh "${IMAGE_REF}"
/opt/ci-gates/sbom.sh "${IMAGE_REF}"
# docker login, then:
export COSIGN_KEY=... COSIGN_PASSWORD=...
/opt/ci-gates/sign.sh "${IMAGE_REF}@sha256:${DIGEST}"
```

SonarQube is **not** a script here: Jenkins `withSonarQubeEnv('sonarqube')` +
`waitForQualityGate abortPipeline: true`.

## Exceptions (`.trivyignore.yaml`)

In the **application** repo, not this one. Every list entry must have:

- `statement` — why we accept the finding
- `expired_at` — `YYYY-MM-DD`, at most 90 days from today

Example:

```yaml
vulnerabilities:
  - id: CVE-2024-1234
    statement: No fix in the distro yet; tracked as issue 42
    expired_at: 2026-12-01
```

`deps.sh` and `image.sh` refuse the file if those fields are missing or the
expiry is more than 90 days away. Secret findings are not excepted here —
gitleaks allowlists live in the app repo (`.gitleaks.toml` / `.gitleaksignore`).

## Tests

`ci/gates/tests/run-tests.sh` — dirty fixture must fail `secrets.sh` and
`deps.sh`; clean fixture must pass. Intentional leak files are under
`ci/gates/tests/fixtures/` and are allowlisted in the **platform** repo
`.gitleaks.toml` so pre-commit does not treat them as real credentials.
