# Replicated runtime acceptance

Plan 63 completed on 2026-11-08; implementation code: `2ee9a49`. Both complete
runtime recipes and all required regression gates pass, including the final
packaged runtime and migration prerequisite reruns.

The owned environment has one shard, two distinct configured server UUIDs and
Keeper. The candidate is `26.3.60.10002.altinitystable`, image
`docker.io/altinity/clickhouse-server@sha256:7e72405bf85df6d163205ee2e56251ebc35daf6dc71142f58bdee7a461690ffb`.
Native client execution is on Darwin against Linux ARM64 containers. The fixture
sets global/background thread pools to 1024/64 before application migration;
the dependency's tiny-fixture 128/8 pools stalled full-schema restart recovery.
The exact image, Keeper setup, migration history and account restrictions remain
unchanged. This is local acceptance, not managed-endpoint or Linux-client
qualification.

The native test driver uses the production connection constructor, writer policy
and consistency helpers. Source cases use Cabal application executables. Packaged
cases use Nix server, admin, PostgreSQL migration and ClickHouse migration
executables with the Cabal native test driver. The qualified Nix output is
`/nix/store/djg3yydgjlzs4la8q2srfx234m1fsck6-kansoku-server-0.1.0.0`.

## Behavioral evidence

The source topology case proves complete UUID coverage, one-shard inventory,
per-connection settings, and a native insert on A followed by synchronized
canonical/public reads on B. Pinned endpoints, unexpected identities, selecting a
replicated schema as direct, and adopting historical direct jobs onto a replicated
target are refused. Failed acquisition closes retained and duplicate handles.

The maintenance case holds native row transmission after an INSERT is visible on
A while administration coordinates on B. The job remains at `created` with its
persistent fence until drain completes. A missing replica, denied observation,
paused mutation and changed persisted identity retain the fence. Repair and resume
require the original complete inventory. Retention recovery independently proves
expired fingerprint scrubbing and expired event deletion on both replicas.

The rebuild case interrupts after TRUNCATE and after a committed rebuild INSERT
before its PostgreSQL checkpoint. Resume clears all targets again and restores the
same canonical event population and finalized contents of all fourteen targets.
Stopping a replica at `rebuilt` and `verified` retains the fence; resuming those
saved stages while the replica is still absent fails. Restoration and fresh
all-replica checks are required before completion.

The writer case uses the actual server/recovery/queue-acknowledgement path. A
stopped replica prevents queue acknowledgement. A controlled native proxy holds
INSERT completion after observing serialized row bytes, independently observes
server commit, then drops the reply. Recovery through the other replica preserves
one physical raw copy on each replica and correct finalized targets. A failed view
target retains the queue until healed; retries repair it without missing or double
logical contributions. Restart/regrouped delivery and multiple server blocks retain
canonical event-once results and finalized target equality.

Raw merges are paused for the physical assertions; raw counts use neither FINAL
nor OPTIMIZE. After the original Keeper block identities are observed to expire
under deliberately shortened owned windows, replay produces two physical raw
copies per replica while canonical facts and finalized targets remain correct:

| Scenario | Physical raw copies on A/B | Canonical copies on A/B |
| --- | --- | --- |
| Lost reply, identical retry within the window | 1 / 1 | 1 / 1 |
| Replay after observed identity expiry | 2 / 2 | 1 / 1 |

Every target is compared on both replicas with its installed SELECT evaluated
from canonical sources and finalized aggregate states. Count-only agreement does
not substitute for this comparison. Strict synchronization is not run while raw
merges are intentionally paused because it would also wait for those merge tasks;
that writer proof uses actual quorum acknowledgement, fresh UUID coverage and
independent per-replica observations.

The read-back case exercises dedicated and fresh pooled physical connections.
With a required source's fetching paused on B, the test observes the helper blocked
in its strict SYSTEM synchronization before releasing the source. A stale SELECT
cannot satisfy the assertion. Ordinary metrics retain eventual consistency and
execute no privileged synchronization commands. HTTP ingestion 202 still precedes
native writer acknowledgement.

## Reproduction and regression gates

From the repository root:

```bash
CLICKHOUSE_MIGRATE_DOCKER_CONTEXT=colima nix develop --no-write-lock-file -c just ch-runtime-replicated
CLICKHOUSE_MIGRATE_DOCKER_CONTEXT=colima nix develop --no-write-lock-file -c python3 scripts/clickhouse_replicated_runtime_acceptance.py --packaged
CLICKHOUSE_MIGRATE_DOCKER_CONTEXT=colima nix develop --no-write-lock-file -c just ch-migrations-replicated
nix develop --no-write-lock-file -c python3 scripts/admin_acceptance.py
nix develop --no-write-lock-file -c just outage-smoke
nix develop --no-write-lock-file -c just native-tls
nix develop --no-write-lock-file -c just check
nix develop --no-write-lock-file -c just guides-check friction-check
nix develop --no-write-lock-file -c okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
git diff --check
```

Completed regression evidence: seven non-skipped direct administration scenario
families; plaintext/trusted TLS success and untrusted/wrong-host refusal before
native application bytes; `just check`, including 507 core examples, 21 client
examples, four probes and both HTTP telemetry semantic/lifecycle modes.
The outage smoke also passes: 8,000 events, a measured 52.0-second outage with a
writer restart, first recovered write in 3.81 seconds, drain in 54.49 seconds and
zero valid-event archives.
The migration prerequisite passes all thirteen source cases and the packaged
full lifecycle, with 72 native query/metrics examples per artifact and no failures
or pending examples. The session rebuild test now uses installed definitions
instead of replaying historical direct-mode schema SQL.

Both full runtime recipes reported:

```text
Replicated runtime acceptance passed: topology, maintenance, rebuild, writer, readback; 2 replicas verified.
```

Both complete runtime recipes explicitly trace the first attempt and retry to
different recorded replica UUIDs. Their lost-reply physical counts remain 1 / 1;
their observed expired-window replay counts are 2 / 2. Strict ADR, guide and
friction validation, formatting, Python compilation and `git diff --check` pass.

Private reports and logs remain under
`.dev/acceptance/`, including per-role settings, UUIDs, image/container ownership,
fence/stage observations, mutation state, physical/canonical populations and all
aggregate comparisons. No fixture password or event selector is published here.

The completion contract requires stable configured identities, all expected
replicas, and separate exclusion of external native readers/writers during
maintenance. Quorum is not a cross-table transaction or power-loss guarantee;
finite block deduplication is not unlimited physical exactly-once storage. The
identity cache's replica-local size estimate remains outside completion proof.
