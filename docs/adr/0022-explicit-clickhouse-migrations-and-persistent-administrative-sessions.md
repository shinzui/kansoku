---
type: Architecture Decision Record
title: Explicit ClickHouse migrations and persistent administrative sessions
description: Embed immutable native migration steps, bind administration to retained target identities, and preserve traffic fences and exact uncertain receipts until explicit recovery.
docId: ADR-22
status: Accepted
date: 2026-10-16
timestamp: 2026-10-16T22:55:08Z
generated:
  by: process:codex
  at: 2026-10-16T22:55:08Z
---

# Explicit ClickHouse migrations and persistent administrative sessions

## Context

The filename-only shell ledger cannot distinguish partial SQL from a lost ledger
acknowledgement. Kansoku has not been deployed, so there is no production history
to import. The [owned acceptance](0010-owned-executable-acceptance-environments.md),
[persistent maintenance](0017-fenced-resumable-administration-and-applied-retention.md)
and [external reader](0018-stable-reader-sql-and-real-consumer-conformance.md)
contracts also apply to native schema changes.

## Decision

Use the released [core](mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate),
[embedding](mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-embed) and
[CLI](mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-cli) cohort in a
separate `kansoku-ch-migrate` executable. Application reads and writes retain their
native driver. Normal startup applies neither store's migrations. PostgreSQL
migrations run first and create additive session coordination state.

The package owns an explicit 25-migration/257-step baseline. Preserve the original
SQL as conversion evidence. Two standalone assertions become explicit
prepare/INSERT-SELECT-check/cleanup steps; one materialization uses the qualified
local synchronous mutation policy. The manifest, original byte ranges and every
adaptation carry exact hashes. Once applied, names, order and SQL bytes are
immutable; subsequent releases append a suffix. Embedding build recipes qualify
inputs by content, including changes with preserved modification times. Source
archives contain those inputs; inspection does not reopen sources at runtime.

Every administrative entry binds an explicit target key, direct endpoint, server
UUID, ledger UUID and persistent PostgreSQL session UUID. Retain the ledger UUID
before the first native submission, including failed initialization. Native history
lives in a separate `kansoku_migration_ledger` Atomic database. Existing application
objects without native history are refused. Legacy adoption and destructive reset
are unsupported; old development data stays under its owner's control.

Migration sessions share administrator lock `(726401,2)` and exclusive traffic
lock `(726401,1)` with data-maintenance jobs, in that order. A separate session
foreign key extends the persistent fence. New and resumed data-maintenance jobs,
Haskell traffic admission and database transaction admission all check both owner
kinds. Temporary backend ownership does not clear a durable fence. Toolkit scope
liveness checks the retained backend's actual exclusive advisory locks.

Before every mutating entry, persist a new predecessor marker. Explicit quiescence
evidence binds the target/session identities and exact preceding entry counter.
The first entry also requires stopping old submitting clients and draining their
native requests. A PostgreSQL lock, elapsed timeout, client death or empty process
list cannot prove that requests have finished or cannot arrive later. Owned proofs
stop their clients and restart their owned native server with its retained data
root; this is an external procedure, not a library guarantee or an automatic
operator action. External SQL schedules must be paused as well.

Persist failed/interrupted outcome state and exact append receipts. Ordinary `up`
and session completion refuse unresolved application outcomes. Repair uses the
public toolkit's position/attempt/step/query validation and requires every retained
receipt. Explicit maintenance reconciliation uses exact-event native observations,
complete history and external drain evidence. A `NotObserved` observation alone
never authorizes mutation. Incompatible or unresolved native history still requires
repair. Native acceptance/finalization send no application SQL; an explicitly
authorized retry can repeat an effect and makes no exactly-once claim.

Only verified current native history under retained exclusion and explicit fresh
predecessor evidence permits session completion. Inspection, errors, process loss
and cleanup failure preserve the fence. Reports and receipts are redacted; any raw
request/effect diagnostics belong in private owned evidence. Preserve primary
native errors even when PostgreSQL outcome recording fails.

The initial proof uses the exact official Darwin/arm64 ClickHouse 26.8.28.14 artifact
from the checked-in qualification matrix. The macOS download self-expands; Nix
expands the hash-verified download in its writable build directory before installing
it. Other platforms fail native execution visibly. Existing Ubuntu acceptance stays
required and blocked on upstream qualification. macOS integration does not select a
deployment platform or qualify Linux. The unknown-cause startup crash, intervening
server patches, actual deployment target and exact production candidate remain
release/deployment gates, recorded in [adoption evidence](../evidence/clickhouse-migrate-adoption.md).
The Kansoku release owner selects the actual target; the upstream toolkit maintainer
qualifies/releases support for required artifacts before Kansoku updates its pin.

## Alternatives considered

Keeping the shell runner alongside native history allows two incompatible ledgers.
Importing undeployed legacy history creates unnecessary recovery obligations.
Transient PostgreSQL exclusion cannot fence native work surviving its backend.
An unconditional cleanup callback cannot attest external drain. Dropping analytics
alone leaves the native ledger current and silently skips schema recreation.
Locally widening the dependency's version allowlist would misrepresent qualification.

## Consequences

Migrations intentionally stop application traffic and require retained identities,
operator evidence and deliberate recovery. Old development stacks must be replaced
with new owned roots, without automatic deletion. Future persistent rollback
restores consistent backups into a separate reviewed target; it does not rewrite
checksums, discard native events or delete only the analytics database. No joint
PostgreSQL/ClickHouse transaction, arbitrary manual-SQL fence, power-loss guarantee
or live deployment follows from this integration.
