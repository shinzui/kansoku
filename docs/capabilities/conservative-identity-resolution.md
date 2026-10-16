---
type: Capability
title: "Conservative identity resolution"
description: "Resolve analytical subjects from explicit users and account-scoped identifier evidence without choosing arbitrary users for ambiguous signals."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-5
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-api"
  - "kansoku-core"
interface:
  - "AnalyticsEvent.identifiers"
  - "canonical_user"
  - "identity-aware metrics"
tags: [identity]
requires:
  - CAP-4
evidence:
  - kind: conformance
    resource: "scripts/identity_acceptance.py"
    proves: "Checks shared sessions, confidence ties, expiry, namespaced identities, account isolation and repeat rebuilds."
  - kind: guide
    resource: "docs/guides/send-events.md"
    proves: "Defines identifier kinds and conservative binding precedence."
---

# Conservative identity resolution

Keep raw identity observations while resolving exact subjects at query time. Explicit users win; shared cookies can resolve within an unambiguous source-service/session scope, otherwise unique retained evidence and confidence rules apply. User and anonymous namespaces remain distinct. Support cookie, device, fingerprint, email_hmac and legacy email_sha256 signals.

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Identity is an analytical inference, not authentication. Ambiguous ties retain the anonymous subject; the service infers no arbitrary transitive user merge or logout. Fingerprints expire after 180 days. New evidence and retention can revise historical answers.

## Requires

- [CAP-4 — Durable delivery and recovery](durable-delivery-recovery.md).

## Evidence

- [identity_acceptance.py](../../scripts/identity_acceptance.py) — Checks shared sessions, confidence ties, expiry, namespaced identities, account isolation and repeat rebuilds.
- [send-events.md](../../docs/guides/send-events.md) — Defines identifier kinds and conservative binding precedence.
