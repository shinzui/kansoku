---
type: Improvement Request
title: Ship one deployment migration command that owns the native session protocol
description: Add a single kansoku-ch-migrate command that a deployment Job runs to apply an image's ClickHouse migrations, owning begin, drain, recovery-set, up, verify and finish itself, with a deployment-declared backup policy, so a deployment no longer hand-builds drain envelopes and recovery manifests and does not break when the protocol tightens.
generated:
  by: process:claude-code
  at: "2026-11-14T22:30:00Z"
requestId: IR-21
status: proposed
origin: mori://tan/tan-app-infrastructure/plans/50-upgrade-kansoku-to-0-2-1-0-on-staging-and-production
acceptanceCriteria:
  - id: AC-1
    statement: One command, for example `kansoku-ch-migrate deploy --json`, applies the image's pending ClickHouse migrations end to end. It begins a fresh session, waits for Kansoku's fenced traffic to drain, runs up, verifies current history and finishes. Its inputs are the retained target, server or replica, and ledger identities that the Job already passes as environment variables, plus an actor and a reason. It writes one JSON report, and exits nonzero with the fence retained on any failure.
    verification: On the direct and replicated packaged fixtures, run the command once with a pending migration and assert the migration applied, the session finished, the fence was released and the report names each step. Make each step fail in turn and assert a nonzero exit with the fence held.
  - id: AC-2
    statement: For a deployment that declares itself app-owned, meaning every ClickHouse submitter is a Kansoku process behind Kansoku's fence, the command produces and records its own owner-bound drain evidence for each entry. The deployment declares the submitter inventory in configuration and supplies no envelope file.
    verification: Run the command with the declared profile and the submitter inventory, and assert the entry audit retains a drain envelope for predecessors 0 and 1 naming the command as the procedure. Without the profile, assert the command refuses and points to the existing --drain-evidence path.
  - id: AC-3
    statement: The deployment chooses a recovery policy. `require` is the default and keeps today's behaviour, requiring --recovery-set before pending SQL. `waive` takes a mandatory reason, and Kansoku records the waiver in the recovery audit as its own kind, never as a snapshot. A deployment can also name a backup hook, a command Kansoku runs inside the fenced, drained interval, which returns the snapshot fields.
    verification: Run with each policy against a pending migration. Assert that `require` refuses without a set, that `waive` applies the migration and retains a waiver row with its reason, and that the hook's snapshots are retained as a normal recovery set.
  - id: AC-4
    statement: Running the command again after success, with nothing pending, succeeds without application SQL or a recovery set. A second deployment of a later image works the same way.
    verification: Run the command twice in a row, then again after adding a migration, and assert both outcomes.
  - id: AC-5
    statement: The command's flags, environment and report are a versioned deployment contract. A Job written against one release keeps working on the next, or that release's changelog names the break and the replacement.
    verification: Packaged acceptance runs a fixed Job script, pinned to the previous release's contract, against the new image. The changelog has a deployment-contract section.
  - id: AC-6
    statement: The migrations guide documents the command, the app-owned profile, the recovery policies and the contract, and the released image is handed to TAN with its digest and source revision.
    verification: Read the guide section and the release record.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-14T22:30:00Z"
    document_timestamp: "2026-11-14T22:30:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Kansoku c25dd7c: kansoku-server/src/Kansoku/ClickHouseMigration/Command.hs
      (drain requirement and KANSOKU_CH_DRAIN_SUBMITTERS), RecoveryGate.hs (recovery-set gate and
      the fresh-empty exemption), docs/guides/clickhouse-migrations.md, and
      tan-app-infrastructure's pulumi/apps/kansoku/migrate-clickhouse.sh. No independent
      verification attestation is claimed.
---

# Ship one deployment migration command that owns the native session protocol

**Authored by:** a `claude-code` session in `mori://tan/tan-app-infrastructure`, while planning
the 0.2.1.0 upgrade
(`mori://tan/tan-app-infrastructure/plans/50-upgrade-kansoku-to-0-2-1-0-on-staging-and-production`).
**Addressed to:** `shinzui/kansoku` agents and the Kansoku release owner.
**Created:** 2026-11-14.


## Why

TAN applies each image's ClickHouse migrations with a Kubernetes Job. The Job runs a shell script
kept in `tan-app-infrastructure` (`pulumi/apps/kansoku/migrate-clickhouse.sh`), which spells out
the native session protocol step by step: `maintenance begin`, `--predecessor 0 up`, `verify`,
then `--predecessor 1 maintenance finish`. The protocol belongs to Kansoku, but the script that
drives it lives in another repository. Each time the protocol tightens, the deployment breaks on
the next upgrade.

That is what happened between `7c1132d` and `c25dd7c`. The 0.2.1.0 tool requires an owner-bound
drain envelope on every mutating entry and on finish (`Command.hs`, `KANSOKU_CH_DRAIN_SUBMITTERS`).
It also requires a three-store recovery set before any pending SQL (`RecoveryGate.hs`). TAN's
script supplies neither, so the unchanged Job would fail at `up` and leave the fence held. To
upgrade, TAN now has to build both JSON documents in BusyBox shell: around twenty fields each,
with exact timestamps and the identities copied from `maintenance recovery-context`. It also has
to keep the old script for the old image, because a Job's pod template cannot change in place.
None of that is TAN-specific. Any deployment of Kansoku would write the same code.

TAN's deployment is the simple case the protocol already describes. Kansoku owns its databases,
the API and writer are its only ClickHouse submitters, and both stop behind the fence that
`begin` sets. Kansoku can attest drain for that case better than an outside script can, because
it is the component that observes the drain.

The recovery set is a policy question that each deployment answers differently. TAN's
environments are not in use yet, and neither managed server has a backup destination
(`system.disks` lists only the local `default` disk). Its owner has chosen to take no backups
for now. Today the only way to express that choice is a manifest whose snapshot entries say
"none", which leaves an awkward record. A first-class waiver would record the decision truthfully,
and a backup hook would let a deployment that does have backups plug them in.


## What TAN would do with it

The Job runs one command from the image, so the protocol and the binary always match. TAN's
script shrinks to a single line, and the upgrade path no longer needs a per-image switch. TAN
would declare the app-owned profile and the submitter inventory (`kansoku_runtime`). It would use
`waive` with a reason until a producer is onboarded, and then move to a backup hook once a
backup destination exists.


## Out of scope

This request does not change the explicit operator protocol, repair, reconciliation, adoption
or shared-server profiles. Those keep their current flags and evidence files. It does not ask
Kansoku to integrate with any backup provider.
