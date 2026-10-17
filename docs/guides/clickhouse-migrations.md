---
type: Runbook
title: "Initialize and upgrade ClickHouse"
description: "Initialize a fresh owned ClickHouse target, retain native identities, coordinate maintenance and recover explicit migration attempts."
docId: DOC-13
tags: ["clickhouse", "migrations", "maintenance", "recovery"]
generated:
  by: process:codex
  at: "2026-10-17T00:54:46Z"
---

# Initialize and upgrade ClickHouse

Use `kansoku-ch-migrate` for explicit native migrations. Normal server startup applies neither
PostgreSQL nor ClickHouse migrations. PostgreSQL must be migrated first. The original shell
runner is retired, and `ch-reset` refuses: dropping only analytics would leave the separate
native ledger current and skip schema recreation.

The qualified integration target is one directly addressed, self-managed ClickHouse
26.8.28.14 server on arm64 macOS, using healthy writable Local disks and synchronous local
effects. `nix develop` supplies the hash-qualified artifact ahead of the template binary.
The [matrix](../../db/clickhouse/qualification/matrix.json) and
[adoption evidence](../evidence/clickhouse-migrate-adoption.md) record its digest and limits.
Linux acceptance is blocked on upstream qualification. The actual deployment target,
intervening server fixes and unknown-cause startup crash remain deployment gates. This
runbook rehearses owned development targets; it is not approval to deploy that candidate.

## Fresh installation

Use a new checkout with new owned database roots. Preserve any old development data until its
owner chooses disposal. A database populated by the filename-only runner is not imported.
Native history begins by executing the compiled 25-migration/257-step baseline. Its reviewed
conversion preserves original SQL byte ranges: two standalone assertions become explicit
prepare/check/cleanup steps, and one materialization uses the qualified local mutation policy.
The [conversion evidence](../../kansoku-server/migrations/clickhouse/provenance.json) records
all three adaptations. There is no SQL splitting or source loading during execution.

Start the dependencies with `just up` in terminal 1. In terminal 2, enter the default development
shell, apply PostgreSQL first, build the executable and inspect the compiled plan:

```bash
nix develop
set -euo pipefail
umask 077
just migrate
migration_package="$(nix build .#kansoku-server --no-link --print-out-paths)"
export CH_MIGRATE="$migration_package/bin/kansoku-ch-migrate"
"$CH_MIGRATE" --help
"$CH_MIGRATE" plan --json
clickhouse-server --version
```

Plan works offline with credentials unset. The expected version is 26.8.28.14; a startup
crash or unsupported version fails the rehearsal. Do not restart repeatedly to turn a failed
qualification case into a pass. The generated command families are `plan`, `status`,
`history`, `verify`, `up`, `repair` and `maintenance`. The inherited `adopt` parser is always
refused by Kansoku before loading configuration or reading its request file.

Verify that the listener and data root belong to this new stack. Only then capture its server
UUID once, generate a ledger UUID, and retain the binding. Credentials remain in the environment
or a secret manager, outside this identity file:

```bash
export KANSOKU_CH_MIGRATION_TARGET='kansoku/local-owned'
export KANSOKU_CH_MIGRATION_ENDPOINT="http://127.0.0.1:$CLICKHOUSE_HTTP_PORT"
export KANSOKU_CLICKHOUSE_USER=default
export KANSOKU_CLICKHOUSE_PASSWORD=''
export KANSOKU_CH_MIGRATION_SERVER_ID="$(clickhouse-client --port "$CLICKHOUSE_TCP_PORT" --query 'SELECT toString(serverUUID())')"
export KANSOKU_CH_MIGRATION_LEDGER_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
mkdir -p .dev/migration-audit
python3 - <<'PY'
import json, os
keys = ['KANSOKU_CH_MIGRATION_TARGET', 'KANSOKU_CH_MIGRATION_ENDPOINT',
        'KANSOKU_CH_MIGRATION_SERVER_ID', 'KANSOKU_CH_MIGRATION_LEDGER_ID']
with open('.dev/migration-audit/target.json', 'x') as output:
    json.dump({key: os.environ[key] for key in keys}, output)
PY
```

Keep this binding after interruption. Subsequent operations load the retained values; they do
not rediscover and trust a new server UUID or generate another ledger UUID. The native ledger
is an Atomic database named `kansoku_migration_ledger`, separate from `analytics`.
`PG_CONNECTION_STRING` addresses the PostgreSQL coordinator created by `just migrate`.

Begin a persistent session before sending any native mutation:

```bash
"$CH_MIGRATE" maintenance begin --json \
  --expect-target "$KANSOKU_CH_MIGRATION_TARGET" \
  --actor "$USER" --reason 'initialize this new owned stack' \
  > .dev/migration-audit/session.private.json
export KANSOKU_CH_MIGRATION_SESSION="$(jq -r .result.id .dev/migration-audit/session.private.json)"
"$CH_MIGRATE" maintenance status --json
```

Begin fences new protected traffic, excludes other administrators, and waits for cooperating
traffic scopes. A process/backend exit does not clear this fence. If begin failed after
persisting a session, `maintenance status` without a session variable finds the active session
matching the retained target/server/ledger binding. Retain that ID and diagnose; do not begin
an unrelated replacement session.

Before the first entry, stop every application/writer and manual administrative client that
could submit requests, and pause external SQL schedules. A native request can outlive the
PostgreSQL backend that admitted it. Stopping clients and restarting the directly owned server
with its retained data root is one reproducible drain procedure. For this local stack:

```bash
export PC_PORT_NUM="${PC_PORT_NUM:-8081}"
process-compose --address 127.0.0.1 --port "$PC_PORT_NUM" process restart clickhouse
```

Wait for the same process to become healthy and verify that `serverUUID()` still equals the
retained UUID. Restart alone is insufficient if old clients can reconnect or a delayed request
can still arrive. An empty `system.processes`, timeout or missing client PID is not drain proof.
Record the actual client-stop/restart procedure, target/server/ledger/session identities and
current predecessor counter in private evidence. Set `DRAIN_EVIDENCE` to that retained reference;
creating a file or supplying `--quiescent` alone does not establish quiescence.

```bash
export DRAIN_EVIDENCE='/secure/path/to/this-entry-drain-record'
predecessor="$("$CH_MIGRATE" maintenance status --json | jq -r .result.entry)"
"$CH_MIGRATE" --predecessor "$predecessor" up --json \
  --initialize-ledger "$KANSOKU_CH_MIGRATION_LEDGER_ID" \
  --expect-target "$KANSOKU_CH_MIGRATION_TARGET" --actor "$USER" \
  --reason 'reviewed fresh native initialization' --quiescent \
  --evidence "$DRAIN_EVIDENCE" > .dev/migration-audit/up.private.json
"$CH_MIGRATE" verify --require-current --guarded --json
```

Only first initialization uses `--initialize-ledger`. If bootstrap was interrupted, retain
that same UUID and use explicit reconciliation/recovery below. Existing native history is
checked under its retained binding; absent history never authorizes replay over old application
objects. Native checksums describe migration history, not arbitrary live-schema equality.

Before finishing, repeat the external drain procedure and retain fresh evidence for the new
predecessor counter. Set `DRAIN_EVIDENCE` to that fresh retained record. Then verify currentness and close the fence:

```bash
predecessor="$("$CH_MIGRATE" maintenance status --json | jq -r .result.entry)"
"$CH_MIGRATE" --predecessor "$predecessor" maintenance finish --json \
  --expect-target "$KANSOKU_CH_MIGRATION_TARGET" --actor "$USER" \
  --reason 'current native history and externally drained predecessors' \
  --quiescent --evidence "$DRAIN_EVIDENCE"
```

Finish refuses unresolved outcomes/receipts, incompatible history or pending migrations. A
failure preserves the fence. Start application traffic and resume external readers only after
successful completion. The migration operator remains the definer of reader views and must
retain their underlying SELECT rights; keep the separately constrained reader role and grants.

## Reload retained identities

When reopening a shell for reuse, upgrade or recovery, enter `nix develop` in the same checkout.
Restore the same PostgreSQL connection and migration operator credentials from your environment
or secret manager, including an explicitly set `KANSOKU_CLICKHOUSE_PASSWORD`. Apply PostgreSQL
migrations first and rebuild/select the new executable. Load the saved binding instead of
repeating the first-install UUID generation:

```bash
set -euo pipefail
umask 077
just migrate
migration_package="$(nix build .#kansoku-server --no-link --print-out-paths)"
export CH_MIGRATE="$migration_package/bin/kansoku-ch-migrate"
export KANSOKU_CH_MIGRATION_TARGET="$(jq -er .KANSOKU_CH_MIGRATION_TARGET .dev/migration-audit/target.json)"
export KANSOKU_CH_MIGRATION_ENDPOINT="$(jq -er .KANSOKU_CH_MIGRATION_ENDPOINT .dev/migration-audit/target.json)"
export KANSOKU_CH_MIGRATION_SERVER_ID="$(jq -er .KANSOKU_CH_MIGRATION_SERVER_ID .dev/migration-audit/target.json)"
export KANSOKU_CH_MIGRATION_LEDGER_ID="$(jq -er .KANSOKU_CH_MIGRATION_LEDGER_ID .dev/migration-audit/target.json)"
"$CH_MIGRATE" plan --json
```

Retain all session reports alongside this binding. For recovery, restore
`KANSOKU_CH_MIGRATION_SESSION` from the matching report's `.result.id`; if begin lost its
response, unset that variable and use `maintenance status --json` to find the active session
under the retained binding. Do not start a replacement session while one remains unfinished.

## Subsequent native migration

Back up both stores consistently, retain the identities and rehearse the new executable against
an isolated restored copy before a persistent rollout. Append native definitions; never edit
applied names, SQL, checksums or their ordering. Inspect the new offline plan, apply any new
PostgreSQL migrations first, and reload the retained identities as above. Stop submitting
clients/read schedules. After confirming the previous session completed, unset
`KANSOKU_CH_MIGRATION_SESSION` and begin a new session with the same native ledger binding,
using the fresh-install `maintenance begin` command with a new reason and a new private report
path. Export that report's `.result.id` as the new session ID. Preserve earlier reports.
Establish external drain before each entry.

After recording fresh external drain evidence for this session/counter, run:

```bash
predecessor="$("$CH_MIGRATE" maintenance status --json | jq -r .result.entry)"
"$CH_MIGRATE" --predecessor "$predecessor" up --json \
  --expect-target "$KANSOKU_CH_MIGRATION_TARGET" --actor "$USER" \
  --reason 'reviewed native upgrade or clean repeat' --quiescent \
  --evidence "$DRAIN_EVIDENCE"
"$CH_MIGRATE" verify --require-current --guarded --json
```

Do not supply `--initialize-ledger` for recurring execution. `up` applies only a compatible
pending suffix. A repeated clean run, after fresh drain evidence, submits no application SQL.
Establish fresh drain again and finish with the fresh-install `maintenance finish` command and
the newly observed predecessor counter. Ordinary `up` does not resume interrupted work or
consume standing repair authorization. Do not run the old shell runner beside native history.

Rollback is a separately reviewed restore of consistent backups into a separate isolated target
with reviewed target/server/ledger identities. Prevent simultaneously active cloned identities.
Restoring analytics alone, changing recorded checksums or deleting native events is not rollback.
No reset, force-clear, legacy import, data deletion or live deployment is automated here.

## Interruption, receipts and explicit repair

Keep the session fence active and preserve stdout/stderr reports, pending receipts and private
diagnostics. Read-only `status`, `history`, `verify` and `maintenance status` remain available.
Stop submitting clients, establish external drain, then inspect fresh guarded history. Each
entry increments the persistent predecessor counter before native SQL, including failed entries.
A stale counter, wrong target or mismatched session/server/ledger identity refuses entry.

`maintenance status --json` exposes `outcome`, `entry` and `pending_receipts`. A killed process
leaves `outcome=submitted`; an observed failure leaves `outcome=failed`. These states block
ordinary up and finish even if a lost ledger response later appears current. Retain every exact
receipt, including secondary recording failures. Supply all of them with repeated
`--pending-append RECEIPT` options to reconciliation or repair.

Explicit reconciliation performs native reads under exclusion. It acknowledges only compatible,
resolved history after external drain; `NotObserved` alone is never permission to submit SQL:

```bash
predecessor="$("$CH_MIGRATE" maintenance status --json | jq -r .result.entry)"
"$CH_MIGRATE" --predecessor "$predecessor" maintenance reconcile --json \
  --expect-target "$KANSOKU_CH_MIGRATION_TARGET" --actor "$USER" \
  --reason 'reconcile retained response loss after external drain' \
  --quiescent --evidence "$DRAIN_EVIDENCE" \
  --pending-append "$RETAINED_RECEIPT"
```

Omit the receipt option only when none is retained. `resolved=false` keeps the outcome pending;
use a selected repair operation with fresh native position/attempt metadata. `PresentIdentical`
is an exact recorded event observation, not proof that unrelated requests have drained.
Interrupted initialization can reconcile absent/uninitialized history only while application
objects remain absent, or resume the matching initialized native ledger. It retains the original
UUID in either case.

Use `repair --help` and the selected operation's help for exact syntax. After external drain,
capture fresh guarded status and the current predecessor counter:

```bash
"$CH_MIGRATE" status --guarded --json > .dev/migration-audit/status.private.json
predecessor="$("$CH_MIGRATE" maintenance status --json | jq -r .result.entry)"
```

From that report, retain `.result.report.observation.position`, the active migration's `attempt`
in `.result.report.migrations`, and the selected step's `attempt.ownerAttempt`, `attempt.step`
and `attempt.queryId` in its `steps` array. Set `POSITION`, `ATTEMPT`, `STEP_ATTEMPT`, `STEP`
and `QUERY_ID` from those reviewed values, and set `DRAIN_EVIDENCE` to fresh evidence for this
session/counter. Do not select a different step merely because a prior command failed:

```bash
"$CH_MIGRATE" --predecessor "$predecessor" repair accept-step --json \
  --expect-target "$KANSOKU_CH_MIGRATION_TARGET" \
  --expect-position "$POSITION" --attempt "$ATTEMPT" \
  --step-attempt "$STEP_ATTEMPT" --step "$STEP" --query-id "$QUERY_ID" \
  --actor "$USER" --reason 'independently verified selected effect' \
  --quiescent --evidence "$DRAIN_EVIDENCE"
```

Include every retained receipt when applicable. `accept-step` attests an observed effect and
sends no application SQL. `retry-step` executes only its explicitly selected statement and can
repeat an effect; it gives no exactly-once guarantee. `resume` runs only never-started steps of
the active migration, then completes that migration. `finalize` records completion of fully
resolved steps without application SQL. Neither accept nor retry automatically runs the suffix.
Every subsequent operation needs fresh counter/position/attempt/evidence as applicable. Unknown
requests, active native work, incompatible definitions and cleanup errors preserve the fence.
