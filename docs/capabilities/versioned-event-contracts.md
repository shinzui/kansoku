---
type: Capability
title: "Versioned event contracts"
description: "Publish governed event schemas and OpenAPI from the same typed contracts used by the running service."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-3
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-api"
  - "kansoku-core"
interface:
  - "GET /v1/schemas"
  - "GET /openapi.json"
  - "kansoku-contracts"
  - "kansoku-openapi"
tags: [ingestion]
evidence:
  - kind: test
    resource: "kansoku-core/test/Kansoku/ContractSpec.hs"
    proves: "Checks the committed catalog, contiguous versions and accepted identifier vocabulary."
  - kind: test
    resource: "kansoku-core/test/Kansoku/OpenApiSpec.hs"
    proves: "Checks generated route and response contracts."
  - kind: guide
    resource: "docs/event-schema-governance.md"
    proves: "Defines additive version governance and publication."
---

# Versioned event contracts

Enforce declared property types and constraints for each event/schemaVersion pair and generate deterministic machine-readable references. Omitted schemaVersion selects version 1. Catalog and OpenAPI reads are public. See [schema governance](../event-schema-governance.md).

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

The registry is authored in Haskell and changes through a service release; there is no runtime schema-management API. Undeclared event names remain admissible without property-schema checks. Generated files must be regenerated rather than hand edited.

## Evidence

- [ContractSpec.hs](../../kansoku-core/test/Kansoku/ContractSpec.hs) — Checks the committed catalog, contiguous versions and accepted identifier vocabulary.
- [OpenApiSpec.hs](../../kansoku-core/test/Kansoku/OpenApiSpec.hs) — Checks generated route and response contracts.
- [event-schema-governance.md](../../docs/event-schema-governance.md) — Defines additive version governance and publication.
