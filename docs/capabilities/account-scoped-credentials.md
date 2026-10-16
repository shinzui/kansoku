---
type: Capability
title: "Account-scoped credentials"
description: "Authenticate producers and analytics consumers with revocable write keys and service tokens scoped to one account."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-1
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-api"
  - "kansoku-core"
  - "kansoku-server"
interface:
  - "Authorization: Bearer"
  - "X-Api-Key"
  - "kansoku-admin issue-key"
  - "kansoku-admin revoke-key"
tags: [ingestion]
evidence:
  - kind: test
    resource: "kansoku-core/test/Kansoku/Auth/HandlerSpec.hs"
    proves: "Checks header precedence, write-key denial on reads, service-token access and credential-store failures."
  - kind: conformance
    resource: "scripts/admin_acceptance.py"
    proves: "Exercises issued credentials and immediate, idempotent revocation against the service."
---

# Account-scoped credentials

Issue account-scoped credentials, store only their hashes, and authenticate every protected request. Write keys admit events; service tokens also access metrics, cohorts and metric definitions. The authenticated account replaces a producer-supplied accountId. See [administration](../guides/administration.md) and [event transport](../guides/send-events.md).

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Credentials authorize analytics access within an account. They do not implement application roles or source-of-truth membership. Public write keys are producer credentials; network access and TLS remain deployment responsibilities.

## Evidence

- [HandlerSpec.hs](../../kansoku-core/test/Kansoku/Auth/HandlerSpec.hs) — Checks header precedence, write-key denial on reads, service-token access and credential-store failures.
- [admin_acceptance.py](../../scripts/admin_acceptance.py) — Exercises issued credentials and immediate, idempotent revocation against the service.
