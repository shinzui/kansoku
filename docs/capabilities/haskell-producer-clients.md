---
type: Capability
title: "Haskell producer SDK and typed clients"
description: "Buffer and retry producer events in Haskell and call ingestion, schema, metric and resource routes through shared typed clients."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-18
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-api"
  - "kansoku-client"
interface:
  - "Kansoku.Client"
  - "Kansoku.Client.Metrics"
  - "kansoku-client-example"
tags: [clients]
requires:
  - CAP-2
evidence:
  - kind: test
    resource: "kansoku-client/test/Spec.hs"
    proves: "Checks batching, interval flush, stable retry IDs, Retry-After, drops, schema helpers and typed routes."
  - kind: example
    resource: "kansoku-client/example/Main.hs"
    proves: "Shows credential configuration, governed event creation and flushing."
---

# Haskell producer SDK and typed clients

Use scoped client lifecycle, buffered batching, explicit flush/close and droppedCount accounting. Helpers emit versioned identity/group events; typed route records cover metrics, paths, cohorts and saved definitions. Retry transient failures with unchanged event IDs and respect server Retry-After. See [the Haskell SDK guide](../guides/haskell-sdk.md).

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

The producer buffer is in memory: overflow drops newest events, and permanent failures or batch rejections increase droppedCount. Flush returns no per-event result. Packages are consumed from a pinned checkout; this repository provides no browser/React producer implementation.

## Requires

- [CAP-2 — Immutable event ingestion](immutable-event-ingestion.md).

## Evidence

- [Spec.hs](../../kansoku-client/test/Spec.hs) — Checks batching, interval flush, stable retry IDs, Retry-After, drops, schema helpers and typed routes.
- [Main.hs](../../kansoku-client/example/Main.hs) — Shows credential configuration, governed event creation and flushing.
