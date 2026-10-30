# Kyverno 1.19.2 Admission Control Notes (Week 4 · ADR 0012)

## 1. First Task: Source & Documentation Evidence for Cosign v3 Bundle Verification in Kyverno 1.19.2

Checked against Kyverno tag `v1.19.2` (commit `e63308f1e16c05cd009ac4864be6ec25c66b49be`, shipped by Helm chart `kyverno` version `3.9.2`) and the live Nexus registry `registry.home.arpa`.

### 1.1 What Our CI Pipeline Publishes to Nexus (`ci/gates/sign.sh`)

Inspecting `registry.home.arpa/v2/belleshop/belleshop-backend` confirmed that Cosign `v3.1.4` (`cosign sign` + `cosign attest --type spdxjson` with an empty `signing-config`) attaches **two** OCI 1.1 referrers via the referrers tag fallback `sha256-352882b7b790190239cf315bfc5b383f762abdef20be34af678770245b2fef26` (`mediaType: application/vnd.oci.image.index.v1+json`):

1. **Image signature bundle** (`sha256:9cf5a8211d63a7408c99ff8e196c6abf5a3c78ab630e14f53ff690db949e58a0`):
   - `artifactType`: `application/vnd.dev.sigstore.bundle.v0.3+json`
   - Single layer `mediaType`: `application/vnd.dev.sigstore.bundle.v0.3+json` (667 bytes)
   - Bundle content: `dsseEnvelope` (`payloadType: application/vnd.in-toto+json`, `_type: https://in-toto.io/Statement/v1`, `predicateType: https://sigstore.dev/cosign/sign/v1`)
   - `verificationMaterial.publicKey.hint`: `5pXkApTy7e55K/HjTuQPkY04R7KQFyJLH+AxfT4xheA=` (no `tlogEntries`, no `timestampVerificationData`)
2. **SPDX SBOM attestation bundle** (`sha256:7e02f2ca11ca0e535ac16d5bb9bd0a0b5b9089ffb8f39be9c2e07146423d0220`):
   - `artifactType`: `application/vnd.dev.sigstore.bundle.v0.3+json`
   - Single layer `mediaType`: `application/vnd.dev.sigstore.bundle.v0.3+json` (3,383,827 bytes; within Kyverno's 10 MiB default `--imageVerifyPayloadLimit`)
   - Bundle content: `dsseEnvelope` (`payloadType: application/vnd.in-toto+json`, `_type: https://in-toto.io/Statement/v0.1`, `predicateType: https://spdx.dev/Document`)
   - `verificationMaterial.publicKey.hint`: `5pXkApTy7e55K/HjTuQPkY04R7KQFyJLH+AxfT4xheA=` (no `tlogEntries`, no `timestampVerificationData`)

### 1.2 `ImageValidatingPolicy` (`policies.kyverno.io/v1beta1`) vs Legacy `ClusterPolicy` (`kyverno.io/v1`)

Both `ImageValidatingPolicy` (`pkg/image/verifiers/ivpol/cosign/`) and legacy `ClusterPolicy` (`pkg/image/verifiers/cpol/cosign/` with `type: SigstoreBundle`) can verify Cosign v3 bundles (`application/vnd.dev.sigstore.bundle.v0.3+json`) stored via the OCI 1.1 referrers tag fallback `sha256-<digest>` with a static key and no transparency log. **`ImageValidatingPolicy` (`policies.kyverno.io/v1beta1`) is chosen** for two concrete reasons found in the Kyverno `v1.19.2` source:

1. **Legacy `ClusterPolicy` is deprecated in Kyverno 1.19:**
   - `pkg/deprecations/deprecations.go` (lines 43–51, 81–96):
     ```go
     // MigrationGuideURL points to the guide describing how to migrate legacy
     // kyverno.io policies to the policies.kyverno.io policy types.
     const MigrationGuideURL = "https://kyverno.io/docs/guides/migration-to-cel/"

     var replacements = map[string]string{
     	"ClusterPolicy":        "ValidatingPolicy, MutatingPolicy, GeneratingPolicy or ImageValidatingPolicy",
     ...
     ```
   - `charts/kyverno/values.yaml` (lines 112–115):
     ```yaml
     # Note: the legacy policy types in this group (ClusterPolicy, Policy, ...) are deprecated and will be
     # removed in a future release, migrate to the policies.kyverno.io policy types
     ```
2. **Legacy `ClusterPolicy` forbids `mutateDigest: true` when `validationFailureAction` is `Audit`, whereas `ImageValidatingPolicy` supports both together:**
   - `api/kyverno/v1/image_verification_types.go` (lines 389–391):
     ```go
     if isAuditFailureAction && iv.MutateDigest {
     	errs = append(errs, field.Invalid(path.Child("mutateDigest"), iv.MutateDigest, "mutateDigest must be set to false for ‘Audit’ failure action"))
     }
     ```
   - By contrast, in `ImageValidatingPolicy`, `pkg/cel/policies/ivpol/engine/engine.go` (`HandleMutating` / `handleMutation`, lines 171–327) and `pkg/webhooks/resource/ivpol/handler.go` (`mutationResponse`, lines 119–146) run digest resolution and return the JSONPatch whenever `mutateDigest: true`, and only block admission on a resolution error if `policy.Actions.Has(admissionregistrationv1.Deny)`. In `Audit` mode (`validationActions: [Audit]`), `mutateDigest: true` and `verifyDigest: true` remain active without requiring policy modifications when switching `validationActions` from `[Audit]` to `[Deny]`.

### 1.3 Source Code Trace of `ImageValidatingPolicy` Cosign v3 Verification (`v1.19.2`)

1. **Static Key + No-Transparency-Log Fast Path (No TUF / Rekor / Fulcio Calls):**
   - `pkg/image/verifiers/ivpol/cosign/opts.go` (lines 85–90, 119, 151–153, 219–232):
     ```go
     // Key/certificate verification with the transparency log ignored needs no
     // Sigstore infrastructure (TUF, Rekor, CTLog), mirroring cosign.
     ignoreTlog := att.CTLog != nil && att.CTLog.InsecureIgnoreTlog
     keyOrCert := att.Keyless == nil && (att.Key != nil || att.Certificate != nil)
     skipSigstoreInfra := keyOrCert && ignoreTlog
     ...
     if !skipSigstoreInfra {
     	trust, err = initTUFAndFetch(ctx, att.TUF)
     ...
     }
     if att.CTLog != nil {
     	opts.IgnoreSCT = att.CTLog.InsecureIgnoreSCT
     	opts.IgnoreTlog = att.CTLog.InsecureIgnoreTlog
     ...
     }
     if att.Key != nil {
     	if len(att.Key.Data) > 0 {
     		opts.SigVerifier, err = decodePEM([]byte(att.Key.Data), signatureAlgorithmMap[att.Key.HashAlgorithm])
     ```
   - `pkg/image/verifiers/ivpol/cosign/verifier.go` (lines 243–245):
     ```go
     func shouldUseSignedTimestamps(ignoreTlog, useSignedTimestamps bool, trustedMaterial root.TrustedMaterial) bool {
     	return ignoreTlog && !useSignedTimestamps && trustedMaterial != nil
     }
     ```
     Because `skipSigstoreInfra` leaves `trustedMaterial == nil`, `shouldUseSignedTimestamps` returns `false` and never requires RFC 3161 TSA timestamps.

2. **OCI 1.1 Referrers Tag Fallback (`sha256-<digest>`) & Bundle v0.3 Detection:**
   - `pkg/image/verifiers/ivpol/cosign/verifier.go` (lines 62–162):
     ```go
     // bundleLayerMediaTypePrefix identifies the layer of a cosign v3 sigstore bundle referrer.
     const bundleLayerMediaTypePrefix = "application/vnd.dev.sigstore.bundle"

     func (v *Verifier) loadBundles(ref name.Reference, registryClientOpts []ociremote.Option) ([]*sgbundle.Bundle, *v1.Hash) {
     	digest, err := ociremote.ResolveDigest(ref, registryClientOpts...)
     	if err != nil {
     		return nil, nil
     	}
     	hash, err := v1.NewHash(digest.Identifier())
     	if err != nil {
     		return nil, nil
     	}

     	index, err := ociremote.Referrers(digest, "", registryClientOpts...)
     ```
     `ociremote.Referrers` (from `github.com/sigstore/cosign/v3/pkg/oci/remote`, backed by `go-containerregistry`'s `remote.Referrers`) queries `/v2/<repo>/referrers/<digest>` and automatically falls back to fetching the OCI image index at tag `sha256-<digestHex>` when the registry returns HTTP 404 on the referrers endpoint (as Nexus 3 does). Each single-layer referrer manifest whose layer mediaType starts with `application/vnd.dev.sigstore.bundle` is parsed via `parseBundleLayer` (`protojson.Unmarshal` -> `sgbundle.NewBundle` -> `b.MinVersion("v0.3")`), setting `cOpts.NewBundleFormat = len(bundles) > 0`.

3. **Image Signature & SPDX SBOM Attestation Verification:**
   - `pkg/image/verifiers/ivpol/cosign/verifier.go` (lines 169–223 `verifyBundles`, lines 247–312 `VerifyImageSignature`, lines 314–377 `VerifyAttestationSignature`):
     ```go
     artifactPolicyOption := verify.WithArtifactDigest(hash.Algorithm, digestBytes)
     ...
     if _, err := cosign.VerifyNewBundle(ctx, &coCopy, artifactPolicyOption, bundle); err != nil {
     	errs = append(errs, err)
     	continue
     }
     dsse, ok := bundle.Content.(*protobundle.Bundle_DsseEnvelope)
     ...
     att, err := ocistatic.NewAttestation(payload)
     ...
     if cOpts.ClaimVerifier != nil {
     	if err := cOpts.ClaimVerifier(att, *hash, cOpts.Annotations); err != nil {
     ```
     And in `VerifyAttestationSignature` (lines 355–374):
     ```go
     for _, s := range sigs {
     	payload, gotType, err := policy.AttestationToPayloadJSON(ctx, attestation.InToto.Type, s)
     ...
     	if len(payload) == 0 {
     		// This is not the predicate type we're looking for.
     		continue
     	}
     	found = true
     	image.AddVerifiedIntotoPayloads(gotType, payload)
     }
     ```
     Upstream unit tests in `pkg/image/verifiers/ivpol/cosign/bundle_verify_test.go` (`Test_V3Bundle_GenuineKeySigned_Verifies`, `Test_V3Bundle_StatementSubjectMismatch_Fails`, `Test_V3Bundle_WrongKey_Fails`, `Test_V3Bundle_OversizedDecoy_AttestationPathSkipsIt`) directly test this exact key-signed v0.3 bundle path.

---

## 2. Policy Type Justification (`policies.kyverno.io/v1beta1`)

All policies in `k8s/platform/kyverno-policies/` use the current CEL policy types in `policies.kyverno.io/v1beta1` (`storage: true` in Kyverno 1.19.2 CRDs):

| Policy | Kind (`policies.kyverno.io/v1beta1`) | Why this type / structure |
|---|---|---|
| `verify-belleshop-images` | `ImageValidatingPolicy` | Native CEL image verification (`verifyImageSignatures`, `verifyAttestationSignatures`), supports `mutateDigest: true`, `verifyDigest: true`, and `required: true` even while `validationActions: [Audit]` is active. |
| `restrict-registries` | `ValidatingPolicy` | Current CEL replacement for `ClusterPolicy` `validate`. Checks `containers`, `initContainers`, and `ephemeralContainers` in one CEL expression. |
| `require-digest` | `ValidatingPolicy` | Split from `disallow-latest` into its own `ValidatingPolicy` because `pkg/cel/policies/vpol/compiler/policy.go` (lines 153–186) short-circuits on the first failing `spec.validations[]` entry; separate policies ensure `PolicyReport` in `Audit` mode surfaces missing digests and `:latest` tags independently. |
| `disallow-latest` | `ValidatingPolicy` | Rejects explicit `:latest` (`image:latest`, `image:latest@sha256:...`) and implicit `:latest` (omitting both `:tag` and `@sha256:`), while allowing digest-only references (`image@sha256:...`). |
| `require-requests-limits` | `ValidatingPolicy` | Uses Kubernetes CEL `isQuantity()` and `quantity(...).isGreaterThan(quantity('0'))` to verify non-zero `requests.cpu`, `requests.memory`, and `limits.memory` on every container. |

In all four `ValidatingPolicy` objects, `spec.autogen.podControllers.controllers` includes `rollouts.v1alpha1.argoproj.io` alongside the built-in controllers (`daemonsets`, `deployments`, `jobs`, `statefulsets`, `replicasets`, `cronjobs`), leveraging Kyverno 1.19's structural pod-template extraction (`pkg/cel/autogen/extraction.go` lines 73–118) so BelleShop's Argo `Rollout` resources are audited directly.

---

## 3. Offline CLI Test Results (`kyverno test` v1.19.2)

Executed with the official pinned Kyverno `v1.19.2` CLI (`commit e63308f1e16c05cd009ac4864be6ec25c66b49be`):

```text
$ kyverno version
Version: 1.19.2
Time: 2026-10-20T22:13:49Z
Git commit ID: e63308f1e16c05cd009ac4864be6ec25c66b49be

$ kyverno test k8s/platform/kyverno-policies/tests
Loading test  ( k8s/platform/kyverno-policies/tests/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Loading exceptions ...
  Applying 4 policies to 10 resources with 0 exceptions ...
  Checking results ...

│──────────│─────────────────────────│──────│─────────────────────────────────────────────────────────│────────│──────────│
│ ID (23)  │ POLICY                  │ RULE │ RESOURCE                                                │ RESULT │ REASON   │
│──────────│─────────────────────────│──────│─────────────────────────────────────────────────────────│────────│──────────│
│ 1        │ restrict-registries     │      │ v1/Pod/dev/good-belleshop-pod                           │ Pass   │ Ok       │
│ 2        │ restrict-registries     │      │ argoproj.io/v1alpha1/Rollout/dev/good-belleshop-rollout │ Pass   │ Excluded │
│ 3        │ restrict-registries     │      │ argoproj.io/v1alpha1/Rollout/dev/good-belleshop-rollout │ Pass   │ Ok       │
│ 4        │ restrict-registries     │      │ v1/Pod/dev/bad-registry-container                       │ Pass   │ Ok       │
│ 5        │ restrict-registries     │      │ v1/Pod/dev/bad-registry-initcontainer                   │ Pass   │ Ok       │
│ 6        │ restrict-registries     │      │ v1/Pod/dev/bad-registry-ephemeralcontainer              │ Pass   │ Ok       │
│ 7        │ require-digest          │      │ v1/Pod/dev/good-belleshop-pod                           │ Pass   │ Ok       │
│ 8        │ require-digest          │      │ v1/Pod/dev/bad-latest-with-digest                       │ Pass   │ Ok       │
│ 9        │ require-digest          │      │ argoproj.io/v1alpha1/Rollout/dev/good-belleshop-rollout │ Pass   │ Excluded │
│ 10       │ require-digest          │      │ argoproj.io/v1alpha1/Rollout/dev/good-belleshop-rollout │ Pass   │ Ok       │
│ 11       │ require-digest          │      │ v1/Pod/dev/bad-tag-without-digest                       │ Pass   │ Ok       │
│ 12       │ require-digest          │      │ v1/Pod/dev/bad-latest-tag                               │ Pass   │ Ok       │
│ 13       │ disallow-latest         │      │ v1/Pod/dev/good-belleshop-pod                           │ Pass   │ Ok       │
│ 14       │ disallow-latest         │      │ v1/Pod/dev/bad-tag-without-digest                       │ Pass   │ Ok       │
│ 15       │ disallow-latest         │      │ argoproj.io/v1alpha1/Rollout/dev/good-belleshop-rollout │ Pass   │ Excluded │
│ 16       │ disallow-latest         │      │ argoproj.io/v1alpha1/Rollout/dev/good-belleshop-rollout │ Pass   │ Ok       │
│ 17       │ disallow-latest         │      │ v1/Pod/dev/bad-latest-tag                               │ Pass   │ Ok       │
│ 18       │ disallow-latest         │      │ v1/Pod/dev/bad-latest-with-digest                       │ Pass   │ Ok       │
│ 19       │ require-requests-limits │      │ v1/Pod/dev/good-belleshop-pod                           │ Pass   │ Ok       │
│ 20       │ require-requests-limits │      │ argoproj.io/v1alpha1/Rollout/dev/good-belleshop-rollout │ Pass   │ Excluded │
│ 21       │ require-requests-limits │      │ argoproj.io/v1alpha1/Rollout/dev/good-belleshop-rollout │ Pass   │ Ok       │
│ 22       │ require-requests-limits │      │ v1/Pod/dev/bad-missing-cpu-request                      │ Pass   │ Ok       │
│ 23       │ require-requests-limits │      │ v1/Pod/dev/bad-missing-memory-limit                     │ Pass   │ Ok       │
│──────────│─────────────────────────│──────│─────────────────────────────────────────────────────────│────────│──────────│

Test Summary: 23 tests passed and 0 tests failed
```

---

## 4. Live Verification of `verify-belleshop-images` Against `registry.home.arpa`

### 4.1 Verified Now via `kyverno apply --registry` Against Live Nexus

Using the `kyverno` `v1.19.2` CLI pointed at `ansible/files/ca/nexus-caddy-root.crt` (`SSL_CERT_FILE`) and the `nexus-pull` credentials against the live signed image `registry.home.arpa/belleshop/belleshop-backend@sha256:352882b7b790190239cf315bfc5b383f762abdef20be34af678770245b2fef26`:

1. **Positive control (`good-belleshop-pod` in `k8s/platform/kyverno-policies/tests/resources.yaml`):**
   ```text
   Applying 1 policy rule(s) to 1 resource(s)...

   pass: 1, fail: 0, warn: 0, error: 0, skip: 0
   ```
2. **Negative control 1 (tampered public key):**
   ```text
   policy verify-belleshop-images -> resource dev/Pod/good-belleshop-pod failed:
   1 - verify-belleshop-images BelleShop image signature verification failed: image must be signed by the homelab Cosign key.

   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   ```
3. **Negative control 2 (wrong attestation `predicateType`):**
   ```text
   policy verify-belleshop-images -> resource dev/Pod/good-belleshop-pod failed:
   1 - verify-belleshop-images BelleShop image SBOM attestation verification failed: image must carry a signed SPDX SBOM (https://spdx.dev/Document).

   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   ```
4. **Negative control 3 (tag-only reference `registry.home.arpa/belleshop/belleshop-backend:c3f1304d2f1a` without mutation):**
   ```text
   policy verify-belleshop-images -> resource dev/Pod/tag-only-belleshop-pod failed:
   1 - verify-belleshop-images image registry.home.arpa/belleshop/belleshop-backend:c3f1304d2f1a does not have a digest

   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   ```

### 4.2 In-Cluster Live Test Plan (After Kubernetes 1.33 Upgrade)

1. **Copy the `nexus-pull` imagePullSecret into the `kyverno` namespace (owner runs out-of-band, never committed to git):**
   ```bash
   kubectl create namespace kyverno --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n dev get secret nexus-pull -o json \
     | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.annotations, .metadata.managedFields) | .metadata.namespace = "kyverno"' \
     | kubectl apply -f -
   ```
2. **Wait for Argo CD to sync `kyverno` (wave 1) and `kyverno-policies` (wave 2), and verify policy readiness:**
   ```bash
   kubectl get ivpol,vpol
   ```
   Confirm `READY=true` (`WebhookConfigured=True` and `RBACPermissionsGranted=True`) on all 5 policies.
3. **Label namespace `dev` to enable Kyverno admission and background scanning on `dev`:**
   ```bash
   kubectl label namespace dev homelab.arpa/admission=enforced
   ```
4. **Verify `Audit` PolicyReports on existing `dev` workloads:**
   ```bash
   kubectl -n dev get policyreport -o wide
   kubectl -n dev get policyreport -o json | jq '.items[].results[] | {policy, result, message, resources}'
   ```
   - Existing `belleshop-backend:latest` and `belleshop-frontend:latest` Pods/Rollouts should report `fail` on `restrict-registries`, `require-digest`, and `disallow-latest`.
   - Existing `mysql:8.0` Pod/Deployment should report `fail` on `restrict-registries` and `require-digest`, and `pass` on `disallow-latest`.
5. **Verify `mutateDigest: true` and Cosign v3 bundle verification on a live dry-run Pod in `dev`:**
   ```bash
   kubectl -n dev run verify-test \
     --image=registry.home.arpa/belleshop/belleshop-backend:c3f1304d2f1a \
     --dry-run=server -o yaml | grep image:
   ```
   Confirm the mutating webhook rewrites `:c3f1304d2f1a` to `:c3f1304d2f1a@sha256:352882b7b790190239cf315bfc5b383f762abdef20be34af678770245b2fef26` and `verify-belleshop-images` records `pass`.
