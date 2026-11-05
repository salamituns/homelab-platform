# Postmortem: Drill 3, an expiring and then expired TLS certificate (isolated, never the real wildcard)

- Date: 2026-11-04 (evening CST; 2026-11-05 UTC)
- Severity: **Low** (planned; only a throwaway TLS server in `chaos-drill3` was affected)
- Status: **Resolved 2026-11-04.** Clean-up in the same PR as this document
- Duration: expiring-soon page 1 h after the cert appeared (the rule's `for: 1h`); expiry detected within one probe
- Author: homelab-platform
- Drill: yes, [ADR 0018](../adr/0018-week8-chaos-drills.md) drill 3 (expired cert), owner-chosen isolated method

## Summary

Before Week 8 no alert watched any certificate's expiry. The pre-drill PR (#66) added `HomelabTlsCertExpiringSoon`
(blackbox `probe_ssl_earliest_cert_expiry`, warning < 21 d, critical < 7 d, `for: 1h`) and scraped cert-manager.
The drill (#69) stood up an isolated nginx TLS server in `chaos-drill3` with a **1-hour** cert-manager certificate
(the cert-manager minimum) and a dedicated blackbox probe, never touching the Gateway listener or the
`*.apps.home.arpa` wildcard. The critical alert fired and emailed one hour later. Then #70 pointed the certificate
at a non-existent issuer; renewal failed and the certificate really expired, and the probe failed with
`x509: certificate has expired`. BelleShop's probes and its 87.6-day wildcard were untouched throughout. The
hypothesis held.

## Timeline (America/Chicago, CST)

| When | What |
|---|---|
| 2026-11-04 21:01:14 | **Injection 1:** #69 merged (isolated target + probe) |
| 2026-11-04 21:07:08 | Certificate `chaos-expiry` Ready, notAfter 22:07:05 (1 h) |
| 2026-11-04 21:07:42 | Server Ready; probe success = 1, 59.3 min left |
| 2026-11-04 21:08:17 | `HomelabTlsCertExpiringSoon` warning + critical **pending** (for: 1h) |
| 2026-11-04 22:08:11 | **Detect:** both **firing**; critical emailed (owner confirmed receipt). The certificate auto-renewed meanwhile (renewBefore 20 m), which is why the alert stayed true |
| 2026-11-04 22:37:27 | **Injection 2:** #70 merged (issuerRef to `chaos-drill3-no-such-issuer`) |
| 2026-11-04 22:38:46 | cert-manager: `Ready=False IncorrectIssuer`; CertificateRequest `chaos-expiry-4` never Ready |
| 2026-11-04 ~23:25-23:27 | **Expired:** served leaf notAfter 23:27:05; probe `probe_success=0`, blackbox: `x509: certificate has expired ... after 2026-11-05T05:27:05Z`. The first failing sample was logged ~90 s before notAfter; not explained by the data captured (see What went badly) |
| 2026-11-04 23:25:37 | BelleShop unaffected: shop probes success = 1, wildcard 87.6 days left |
| clean-up | This PR removes the app, probe, module and netpol rule; owner deletes the namespace and Application (platform-root does not prune) |

## Root causes

1. **Certificates had no expiry detection at all before this week.** cert-manager was deliberately not scraped,
   and no rule read `probe_ssl_earliest_cert_expiry`. A forgotten renewal (a broken issuer, as injected here)
   would have been discovered by users seeing TLS errors. Fixed by #66 and proven by this drill.
2. **The lab CA is name-constrained to `home.arpa`,** so a test certificate for an in-cluster `.svc` name fails
   verification immediately; the drill needed a `home.arpa` name plus an SNI override in a separate blackbox module.
   Good for security, easy to trip over when testing.
3. **cert-manager's minimum duration is 1 h,** and the alert waits `for: 1h`, so the earliest possible page for a
   fresh short-lived certificate is about 1 h. That is fine for real certificates (weeks of warning) and only
   matters for drills.

## What worked

- Detection end to end: probe metric -> rule -> Alertmanager critical route -> email.
- Isolation: separate namespace, probe label `slo: chaos-drill`, its own module and netpol rule; the Gateway, the
  wildcard, `lab-ca` and BelleShop were never touched (verified at the end).
- cert-manager fail-closed behaviour: with a missing issuer it kept serving the old certificate until it expired,
  rather than deleting it early.
- The agent that built it caught the name constraint and the 1 h minimum by testing against the live API
  (`--dry-run=server`) before anything merged.

## What went badly

- The first failing probe sample was logged about 90 s before the certificate's notAfter, and the Certificate's
  status briefly lost its notAfter at the same moment. The later blackbox error shows a genuine expiry; the early
  sample was not explained with the data captured (possible nginx reload or cert-manager status rewrite).
- Clean-up needs a manual delete: `platform-root` has `prune: false`, and the Application has no finalizer, so
  removing it from git leaves the Application and namespace running.

## Action items

- [ ] Clean-up (this PR) plus owner: `kubectl -n argocd delete app chaos-drill3 && kubectl delete ns chaos-drill3`
- [ ] Consider a resources finalizer on drill/test Applications so removing them cascades
- [ ] Optional: page on `probe_success == 0` for non-SLO probes too (today an expired cert on a non-SLO host only
      shows as the expiry alert and a failing probe in the UI)

## Lessons

1. **You cannot detect what you do not measure.** The expiry was invisible until a metric and a rule existed;
   drills are how you find those blind spots before users do.
2. **Drill on a copy, never on the shared thing.** The isolated target proved the same detection path with zero
   risk to the real certificate and listener.
3. **Security constraints shape your tests.** The CA's name constraint is a feature; test fixtures must live
   inside it.
