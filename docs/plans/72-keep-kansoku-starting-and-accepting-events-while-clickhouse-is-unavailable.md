---
id: 72
slug: keep-kansoku-starting-and-accepting-events-while-clickhouse-is-unavailable
title: "Keep Kansoku starting and accepting events while ClickHouse is unavailable"
kind: exec-plan
created_at: 2026-11-13T16:06:19Z
intention: "intention_01m7atfzwfej88bx8whfb0xp5h"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-13T16:06:19Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-13T16:19:31Z
      mode: "implement"
      note: "Implement writer validation, independent startup, operational health split, owned acceptance and release handoff"
---

# Keep Kansoku starting and accepting events while ClickHouse is unavailable

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Record implementation friction through agents/skills/exec-plan/FRICTION.md and distill durable decisions into docs/adr/ before completion.


## Purpose / Big Picture


Kansoku must start and accept events into PostgreSQL when one or every ClickHouse server is unavailable. After storage returns, the same running writer must drain the queue safely. An observed topology or schema mismatch must stop inserts while leaving startup and ingestion available. Operators will use /health/ready for traffic admission and /health/pipeline for delivery health.

This implements all six acceptance criteria in [IR-15](../improvement-requests/keep-kansoku-starting-and-accepting-events-while-clickhouse-is-unavailable.md). [Plan 63](63-keep-writes-and-maintenance-jobs-correct-on-a-replicated-cluster.md) implemented replicated writing and maintenance; [Plan 62](62-run-clickhouse-migrations-on-a-replicated-cluster.md) implemented replicated migrations. Both are present and marked complete. This plan is standalone. The requesting deployment is mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster.

PostgreSQL outages, invalid local configuration and deliberate maintenance exclusion remain valid reasons to reject traffic. Metric queries may still return retryable 503 during ClickHouse outages. Deploy-time migration jobs continue requiring ClickHouse. Completion includes operations guidance and a released-image handoff to TAN.


## Progress


- [ ] Milestone 1: Writer validation distinguishes unavailable storage from observed mismatch, prevents unsafe inserts, and retries retained events.
- [ ] Milestone 2: Startup performs no ClickHouse exchange before listening; admission and pipeline health have separate tested contracts.
- [ ] Milestone 3: Owned packaged-server acceptance proves bounded startup, continuing admission, mismatch refusal and recovery in both topologies.
- [ ] Milestone 4: Guidance, ADRs and passing regression checks describe the buffering guarantee and finite capacity.
- [ ] Milestone 5: A qualified immutable image is released with digest, source revision, plan hashes and TAN probe guidance.

Implementation checkpoint, 2026-11-13: Structured validation, independent startup, the three health routes and both owned fixture paths are implemented. The representative Nix-native recovery proof passed direct and replicated modes (startup-to-persistence 0.22/0.23 seconds; first recovered write 0.77/1.76 seconds; drain 1.03/3.11 seconds; unchanged server PIDs, exact per-replica IDs, zero archives). The rebuilt expanded suite and just check passed 553 core and 23 client examples, four shared conformance tests, both HTTP telemetry modes, document/profile checks and fifteen release-validator tests. The Nix-packaged replicated representative also passed (0.23-second startup, 2.03-second first recovery write, 3.98-second drain); packaged startup/admission variants, complete mismatch and production-version qualification, full store regressions and release remain open.


## Surprises & Discoveries


2026-11-13: Mori discovery still fails on its local PostgreSQL socket; FRIC-32 records the dependency-source lookup detour. The Nix shell supplies ClickHouse server and Keeper 26.8.28.14 for the fast native development loop.


2026-11-13: The first native recovery interaction exposed inherited result truncation: a profile with max_result_rows=1 and overflow=break returned a partial clusterAllReplicas inventory. Inventory observations now explicitly disable result truncation and skipped unavailable shards so incomplete exchange cannot masquerade as a valid topology result. The failed run retained its queue and parked safely.


## Decision Log


2026-11-13: Keep /health/ready as traffic admission and add /health/pipeline for delivery health. TAN already uses readiness for Kubernetes traffic admission. Existing ClickHouse/backlog alerts based on readiness must move to pipeline health or metrics.

2026-11-13: Remove live ClickHouse validation from startup. Retry it asynchronously for diagnostics and independently before writer inserts. Neither a ping nor an old healthy observation authorizes insertion. Both unavailable storage and observed mismatch retain events, with distinct diagnostics.

2026-11-13: Preserve all-replica quorum, maintenance exclusion, immutable migrations and logical event-once analytics. This plan does not extend finite native block deduplication into unlimited physical exactly-once storage.

2026-11-13: Following the implementation-session instruction, use the Nix-provided native ClickHouse/Keeper for day-to-day development and regression checks. Retain the exact production-version Apple Container fixture for major qualification. Keep native Darwin 26.8 and production-version Linux Altinity evidence separate; never use Docker or Colima for ClickHouse.


## Outcomes & Retrospective


(To be filled during implementation.)


## Context and Orientation


Events are committed to PostgreSQL before HTTP 202. PGMQ implements the durable queue; the acceptance ledger records accepted event identity and payload so producer retries do not republish. A background Shibuya processor leases messages, temporarily hiding them without deletion, inserts batches into ClickHouse, and acknowledges the queue only after success. In kansoku-core/src/Kansoku/Writer/Recovery.hs, failed batches retain their payloads and renew leases while further queue pulls pause. Its breaker states are Closed, Unavailable and Parked. Parked is retryable and denotes a storage rejection needing attention. Current defaults are a five-second recovery probe interval, 750 ms native ping timeout and thirty-second insert deadline.

kansoku-server/app/Main.hs calls validateClickHouseTopology before opening PostgreSQL or binding HTTP. In kansoku-core/src/Kansoku/ClickHouse.hs, direct startup tolerates unavailable observation after 750 ms but throws on observed schema mismatch. Replicated startup requires every expected UUID, a server's stable unique identity, through withReplicaConnections in kansoku-core/src/Kansoku/ClickHouse/Consistency.hs, with 64 observations and a 35-second deadline. kansoku-core/src/Kansoku/ClickHouse/Native.hs currently wraps mismatch, connection failure and deadline in one ConsistencyError Text.

kansoku-core/src/Kansoku/ClickHouse/Topology.hs parses direct or replicated configuration. Direct selects an independent server. Replicated selects one shard, a partition of the dataset, with several copies identified by expected UUIDs and a cluster name. Runtime reuses KANSOKU_CH_MIGRATION_CLUSTER and KANSOKU_CH_MIGRATION_REPLICA_IDS. The consistency module's roleSettings requires synchronous inserts and quorum equal to the entire expected replica count: every copy acknowledges. The twenty-second quorum wait remains inside the thirty-second insert deadline.

newWriterConnection is lazy, but physical initialization currently checks only that connection's schema, membership and settings. Removing startup validation without adding full inventory validation at the writer would weaken safety. kansoku-core/src/Kansoku/Writer/Run.hs owns processing and maintenance admission; its recovery ping is only a retry hint. Query connections use a separate lazy pool.

kansoku-core/src/Kansoku/Server.hs combines writer liveness, PGMQ reachability, native query reachability, queue depth and flush age in readiness. kansoku-core/src/Kansoku/Readiness.hs computes the last two from cached queue samples. kansoku-core/src/Kansoku/Health.hs owns operational paths outside customer OpenAPI. kansoku-core/src/Kansoku/Telemetry.hs annotates these routes; kansoku-core/src/Kansoku/RequestLog.hs excludes probePaths. Checks have 750 ms slot deadlines, a two-second total deadline and failure-onset tracking. Unexpected worker death already terminates the process. The PostgreSQL maintenance fence is persistent state and locking that deliberately rejects protected traffic during administration.

Relevant ADRs were discovered by scanning docs/adr/ filenames and headings. [ADR-2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md) defines canonical health JSON, privacy, queue sampling and recovery; revise its combined-readiness decision. [ADR-4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md) defines logical event-once analytics and quorum; revise its fatal startup boundary while preserving replay. [ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires real packaged executables, owned stores and no skipped cases. [ADR-22](../adr/0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md) preserves immutable migrations and retained administrative fences. [ADR-24](../adr/0024-package-tan-images-from-the-source-flake.md) defines clean images, exact plan hashes and digest-bound handoff. mori.dhall declares the profiled ADR bundle at docs/adr/profile.dhall; changed ADRs require strict validation and log updates.

scripts/clickhouse_replicated_runtime_acceptance.py, scripts/replicated_clickhouse.py and kansoku-server/test/ClickHouseReplicatedRuntime.hs provide real runtime cases but currently assume Docker discovery. scripts/apple_clickhouse_fixture.py already owns exact Altinity 26.3.60.10002.altinitystable Linux ARM64 replicas and Keeper, their replication coordination service, with sufficient full-schema thread pools. It exports native ports and direct mode but exposes stop without restart. Extend that interface; do not start Colima. scripts/outage-acceptance.py provides direct packaged-server outage/restart regression.

Current cabal.project and flake.module.nix select released migration cohort 0.2.0.0. Historical Plan 64 release evidence selects an older source candidate; scripts/check_tan_release.py still expects commit-shaped toolkit fields. New release validation must represent the actual cohort while preserving historical evidence. Mori discovery during planning failed because its local PostgreSQL socket refused connections. No new dependency version or external API is selected here; repeat Mori discovery before dependency-facing implementation.


## Plan of Work


### Milestone 1: Validate storage at the writer boundary


Introduce structured unavailable/indeterminate versus observed-mismatch categories with safe reasons in kansoku-core/src/Kansoku/ClickHouse/Native.hs. Update consistency helpers and all ConsistencyError callers. Network failures and deadlines are unavailable; do not classify arbitrary exception text as a positive topology observation. Administrative callers retain their redacted fail-closed behavior and fences.

Factor complete runtime validation: direct schema compatibility; replicated full UUID coverage, one-shard cluster cardinality, exact cluster UUID inventory, compatible schemas and checked writer settings. Share logic between the observer and writer, but bind writer evidence to the actual physical connection used for insertion. Revalidate before each batch, including cached handles. On failed observation submit no event INSERT, invalidate physical handles and close partial acquisitions. Background health cannot authorize writing.

Use an eight-second runtime validation budget including connection setup and cleanup, retaining the 64-observation cap. Keep the administrative 35-second policy independent. Compose validation with the twenty-second quorum wait within the existing thirty-second attempt deadline. Prove one real roundtrip under this composition before expanding cases; revise all affected bounds together if integration evidence requires a different composition. Timeout is Unavailable, never permission to reduce quorum.

Update kansoku-core/src/Kansoku/Writer/Recovery.hs: mismatches park with safe transition reasons, unavailable observations enter Unavailable, and both retry without archiving or acknowledging valid messages. Preserve lease renewal, bounded retention and asynchronous cancellation. Extend kansoku-core/test/Kansoku/ReplicaTopologySpec.hs and kansoku-core/test/Kansoku/Writer/RecoverySpec.hs plus native coverage. Acceptance requires distinct classification, zero INSERT under unsafe inventory, cleanup on cancellation and successful retained-batch retry after correction.


### Milestone 2: Start independently and split health signals


Remove startup validation in kansoku-server/app/Main.hs and ensure query/writer constructors allocate without waiting on ClickHouse. Launch a supervised asynchronous topology observer even with an empty queue. Begin Unchecked, bound observations to eight seconds, wait five seconds between attempts, and record observation time, category and safe reason. A sample older than twenty seconds is stale. Ordinary storage failures remain in its retry loop; unexpected observer death remains supervised. Cancellation closes observer resources.

Change /health/ready in kansoku-core/src/Kansoku/Server.hs to evaluate only bounded PostgreSQL/PGMQ admission reachability. Preserve invalid-configuration and queue-provisioning failures. Writer death already terminates the process; recoverable storage failure cannot fail admission. Preserve the maintenance middleware's rejection of protected traffic.

Add /health/pipeline to kansoku-core/src/Kansoku/Health.hs using the exact existing status, check and failingSince JSON fields and HTTP 200/503. Allocate independent failure trackers for live, admission and pipeline. Pipeline includes writer liveness, PGMQ reachability, fresh successful topology observation, native query reachability, queue/flush thresholds and breaker state. Fixed names include clickhouse_topology_unchecked, clickhouse_topology_unavailable, clickhouse_topology_mismatch, clickhouse_topology_stale and writer_storage_parked. Detailed safe reasons belong in transition logs, never arbitrary metric labels. The observer owns its snapshot; the writer owns its breaker state.

Preserve 750 ms slots and two-second endpoint deadlines; HTTP must not perform full inventory scans. Update operational route annotation, probePaths and log exclusions. All three paths remain outside customer OpenAPI, auth, CORS and body limits. Extend kansoku-core/test/Kansoku/HealthSpec.hs, kansoku-core/test/Kansoku/ReadinessSpec.hs, kansoku-core/test/Kansoku/HttpTelemetrySpec.hs and kansoku-core/test/Kansoku/RequestLogSpec.hs. Preserve the existing kansoku-probe-test shared two-probe adapter while adding pipeline coverage. Acceptance is readiness 200/pipeline 503 during storage and backlog failure, readiness 503 on PostgreSQL failure, and correct schema, timestamps, deadlines, privacy and cancellation.


### Milestone 3: Prove packaged startup and recovery


Create scripts/clickhouse_buffering_acceptance.py with --packaged and --case startup|admission|recovery|mismatch; omission runs every case. Use scripts/native_clickhouse_fixture.py with the Nix-provided Darwin 26.8 server/Keeper for the normal development loop. Retain --production-fixture with scripts/apple_clickhouse_fixture.py for exact Altinity Linux major qualification. Reuse scripts/isolated_postgres.py and scripts/test_support.py. Add owned stop/start callbacks preserving data roots and UUIDs; retain exact child PIDs/container identities rather than matching names. Adapt the old runtime bridge to owned Nix native ports by default and preserve exact Apple fixture ports for production-version qualification on macOS without breaking migration consumers. Missing prerequisites or zero selected cases must fail.

First prove one representative interaction: initialize healthy owned stores through actual PostgreSQL/native migration executables, finish maintenance, issue a disposable write key, stop one replica, start the packaged server, enqueue an event, restore that replica and observe the same process drain it. This tests the uncertain combination of validation, deadlines, driver, maintenance and quorum before multiplying scenarios.

Cover startup with one stopped replica, all replicated servers unreachable and direct storage unreachable. Include refused connections and a controlled TCP endpoint that stalls native handshake. Measure from launch of the already-built binary; require listening, live/ready 200, valid event 202 and its persisted queue row within ten seconds. Build/migration time is outside this bound. Record the unchanged server PID throughout the outage.

Configure queue sampling one second, flush-age threshold two seconds and queue-depth threshold one event. Keep at least three unique events queued for at least five seconds. Throughout partial/full outages, assert admission 200 and further ingest 202 while pipeline 503 and queue/age/breaker metrics expose failure. Restore stores; require first successful write within sixty seconds and small-fixture drain within 120 seconds without restart. Independently compare exact accepted IDs in every replica's canonical result, one logical event per ID, empty queue and zero valid archives. In controlled no-insert outage cases also inspect physical raw counts without FINAL or OPTIMIZE. Preserve existing lost-acknowledgement and expired-deduplication tests as distinct guarantees.

Mismatch cases include unexpected UUID, wrong replica inventory/cluster cardinality and direct mode against replicated schema. Assert live/ready 200, event 202, retained messages, typed pipeline mismatch and safe reasons, even with an initially empty queue. Observe zero event INSERT submissions using the proxy or query log as well as unchanged counts. Repair the target behind the same stable endpoint and drain without restart. Environment selectors cannot change in a running process: test their correction as a rollout retaining PostgreSQL queue contents, without claiming hot reload. Change a target after prior success to prove cached writer validation.

Stop owned PostgreSQL and require ready 503. Exercise maintenance independently and require protected ingest 503. Retain private logs, versions, platforms, timings, accepted IDs, package/source identity, per-replica evidence and zero-skip counts. Publish sanitized summaries in docs/evidence/clickhouse-buffering/. Add just ch-buffering-acceptance to build required components and invoke the packaged harness. This milestone proves AC-1 through AC-5.


### Milestone 4: Align guidance and regression evidence


Update docs/guides/operations.md, docs/guides/capacity.md, README.md, kansoku-api/test/hurl/health.hurl and consumers of old readiness semantics. Retain KANSOKU_READY_MAX_QUEUE_DEPTH and KANSOKU_READY_MAX_FLUSH_AGE_SEC for configuration compatibility, assigning them to pipeline diagnostics and alerts. Explain replica selectors/grants, PostgreSQL capacity, queue/oldest-age monitoring, query 503s, rollout behavior and explicit migration-job requirements.

Document finite buffering from measured queue-plus-ledger cost, retained WAL, reserved disk, headroom and arrival rate. Conservative outage seconds equal usable disk divided by incoming events per second times measured bytes per event. Drain requires write capacity above continued arrival rate. Link existing workload-specific measurements without promising their duration for production.

Update ADR-2 and ADR-4 for the new health/startup contracts, ADR-10 for the actual Apple execution boundary, and ADR-22/ADR-24 only where their durable context changes. Preserve historical evidence and immutable migrations. Maintain timestamps and bundle logs with normal OKF commands and validate strictly. Run just check, packaged acceptance, direct outage smoke and replicated runtime regressions on the adapted Nix fixture; additionally retain exact production-version qualification evidence for this major runtime change. Record actual counts and architectures. Repeat the ten-minute capacity proof only if batching, retention or resource bounds change. Acceptance requires matching guidance and passing protocol, privacy, replay and maintenance regressions.


### Milestone 5: Release and hand off the image


Follow ADR-24 and docs/plans/64-accept-tan-production-as-a-deployment-target.md for a new clean source candidate, preserving previous release records. Store candidate evidence, image report, exact offline plans, publication receipts and TAN handoff under docs/evidence/clickhouse-buffering/. Use Conventional Commits with ExecPlan: docs/plans/72-keep-kansoku-starting-and-accepting-events-while-clickhouse-is-unavailable.md and Intention: intention_01m7atfzwfej88bx8whfb0xp5h trailers.

Prefer local Apple Container for Linux execution, falling back to remote builders only when local requirements cannot be satisfied. Exercise exported Linux amd64 entrypoint/mapping, CA and offline-plan smoke with Apple Container and Rosetta, reporting emulation accurately. Exercise image-based buffering startup/ingest/recovery or explicitly retain remaining image coverage gaps in the candidate's established owner disposition. Native host-client evidence cannot count as Linux-image behavior.

Adapt scripts/check_tan_release.py and scripts/test_check_tan_release.py to validate the actual released cohort and committed Cabal/Nix agreement while preserving historical commit-based records. Verify registry and upstream tag/source identity before choosing any new dependency. Never fabricate a commit from a version string or reuse old owner approval for a new image.

Capture direct-native, replicated-native and PostgreSQL plan --json stdout including final newlines; hash their exact bytes separately. TAN's nativePlanSha256 maps to the replicated plan. Use scripts/check_container_image.py and the updated release validator to bind clean revision, archive/configuration identities, tested image and final registry-manifest digest. Preserve immutable tags and verify registry readback. Follow the existing release-owner approval boundary for unresolved risks. A prepared null-image artifact is not published.

The concrete repository-local handoff states digest, full source revision, upstream identity, plan hashes, evidence, buffering limits and probe instructions. TAN retains /health/live for liveness and /health/ready for admission, adds /health/pipeline monitoring and moves old ClickHouse/backlog alerts there. State query/migration behavior. Record the artifact for TAN's normal deployment without deploying or sending external messages. AC-6 and this milestone remain open until publication is verified and the handoff exists.


## Concrete Steps


Run commands from the repository root, /Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku in the authoring checkout. Plan creation has not built a release or run native acceptance.

```bash
mori registry list
mori registry search servant-health
mori registry search shibuya
mori registry search clickhouse-migrate
mori registry show shinzui/clickhouse-migrate --full
mori registry docs shinzui/clickhouse-migrate
nix develop --no-write-lock-file -c just build-with-tests
nix develop --no-write-lock-file -c just deterministic-test
```

Mori should return qualified names and source/doc paths. Inspect dependencies on disk before changing API use and verify authoritative registries/tags before changing bounds. If discovery remains unavailable, record the local service error and avoid guessing. Never traverse /nix/store or /. Builds must exit zero; deterministic checks require nonzero cases, zero failures and zero pending examples.

After adding the new harness/recipe, run the representative path and full gates:

```bash
nix develop --no-write-lock-file -c clickhouse keeper --version
nix develop --no-write-lock-file -c python3 scripts/clickhouse_buffering_acceptance.py --packaged --case recovery
nix develop --no-write-lock-file -c just ch-buffering-acceptance
nix develop --no-write-lock-file -c just ch-buffering-acceptance --production-fixture
nix develop --no-write-lock-file -c just check
nix develop --no-write-lock-file -c just acceptance
nix develop --no-write-lock-file -c just outage-smoke
nix develop --no-write-lock-file -c just ch-runtime-replicated
nix develop --no-write-lock-file -c okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
nix develop --no-write-lock-file -c just guides-check
git diff --check
```

The new harness/recipe and Apple runtime adaptation are implementation deliverables; do not run the old bridge by starting a Docker substitute. Required gates exit zero with actual nonzero case counts and no skips. The new harness ends with ClickHouse buffering acceptance passed and identifies both topology families.

For release preparation use a fresh private output directory; do not overwrite earlier candidates. Populate candidate.json using the updated validator schema and actual qualification evidence before validation.

```bash
mkdir -p .dev/acceptance/buffering-release
nix build .#kansoku-server .#kansoku-admin .#kansoku-ch-migrate .#kansoku-migrate --no-link --no-write-lock-file
nix run .#kansoku-image-stream --no-write-lock-file > .dev/acceptance/buffering-release/image.tar
skopeo copy docker-archive:.dev/acceptance/buffering-release/image.tar oci-archive:.dev/acceptance/buffering-release/image.oci.tar
candidate_revision=$(git rev-parse HEAD)
nix develop --no-write-lock-file -c python3 scripts/check_container_image.py --engine apple --archive .dev/acceptance/buffering-release/image.tar --oci-archive .dev/acceptance/buffering-release/image.oci.tar --revision "$candidate_revision" --report .dev/acceptance/buffering-release/image-report.json --plan-dir .dev/acceptance/buffering-release/plans
nix develop --no-write-lock-file -c python3 scripts/check_tan_release.py --phase prepared --evidence .dev/acceptance/buffering-release/candidate.json --image-report .dev/acceptance/buffering-release/image-report.json --plan-dir .dev/acceptance/buffering-release/plans --artifact .dev/acceptance/buffering-release/prepared-artifact.json
```

Keep plans/ absent until the checker captures output: it refuses overwrites. A prepared artifact has image: null; exit 2 means pending gates. After authorized publication/readback fills a distinct published record, run the validator with --phase published, its evidence path and a fresh artifact path. It must exit zero with the verified registry digest. Add exact publication commands and candidate inputs to this living plan when those inputs exist.


## Validation and Acceptance


AC-1 and AC-2 require live/ready 200, event 202 and its durable queue row within ten seconds after launch with one stopped replica, all replicas unavailable or direct storage unavailable. Test refused connections and stalled handshakes, recording actual process identity. A mock app or listening socket alone does not prove acceptance.

AC-3 requires a backlog beyond both configured depth/flush thresholds, continuous admission 200 and additional ingest 202 during partial/full outage. Pipeline reports storage failure even before the first event; metrics expose backlog and breaker. PostgreSQL failure makes readiness 503 and maintenance still rejects protected traffic. Tests prove admission never evaluates storage/writer callbacks, while all health paths preserve schema, independent failure onset, budgets, cancellation and privacy.

AC-4 requires first recovered write within sixty seconds and full small-fixture drain within 120 seconds without server restart. Check exact accepted IDs once logically on every expected replica, actual all-replica settings, empty queue and zero valid archives. Read replicas independently; counters alone are insufficient. Preserve physical lost-reply and late-replay distinctions.

AC-5 requires each mismatch to retain accepted events with zero INSERT submissions and a safe diagnostic. Same-endpoint target repair recovers without restart; environment correction is a rollout retaining the queue. A changed target after success must also be refused. Administrative topology rejection and retained-fence regression remain required.

AC-6 requires matching operations/capacity guidance, passing document/regression checks and a verified published image with source revision, manifest digest, exact plan hashes and concrete TAN handoff. State tested architectures and Rosetta scope. Pending qualification/publication leaves Milestone 5 incomplete.


## Idempotence and Recovery


Each behavioral run owns fresh stores, credentials, ports, recorded process/container identities and retained evidence under .dev/acceptance/. Stop only those resources on success, failure and signals. Restore the same replica UUID and writable inventory before readback; retain failed restart observations instead of silently retrying uncertain fixture operations. Never target ambient stores or use broad process-name termination.

No migration or queue conversion is planned. Do not clear, archive or modify valid messages to make checks pass. Correct topology rather than downgrading mode, accepting partial inventory, relaxing TLS or reducing quorum. Runtime retry cannot release unresolved maintenance fences.

Keep the prior immutable digest for rollback and retain PostgreSQL messages. Reverting the image also restores former outage-sensitive startup/readiness behavior; state that limitation in the handoff. Use fresh candidate output paths and immutable tags; preserve historical records. Prepared artifacts cannot identify published releases.


## Interfaces and Dependencies


Operational contracts are GET /health/live for responsiveness, GET /health/ready for ingest dependencies and GET /health/pipeline for delivery health. All use the existing exact status, check, failingSince JSON schema and HTTP 200/503. kansoku-core/src/Kansoku/Health.hs owns the complete operational route/path inventory; kansoku-core/src/Kansoku/Server.hs owns injectable checks/deadlines. Preserve customer API separation and the shared two-probe conformance adapter.

kansoku-core/src/Kansoku/ClickHouse/Native.hs exposes unavailable versus observed-mismatch categories and safe reasons. kansoku-core/src/Kansoku/ClickHouse/Consistency.hs owns full validation and independent runtime/administrative budgets. kansoku-core/src/Kansoku/ClickHouse.hs owns lazy physical resources and insert admission. kansoku-core/src/Kansoku/Writer/Recovery.hs consumes categories without weakening cancellation or acknowledgement. Observer snapshots and writer breaker state have separate owners.

PostgreSQL/PGMQ remain durable ingest dependencies, Shibuya remains the batch/lease processor and vendored ClickHaskell remains native transport. No dependency upgrade is required. Use Mori before changing external APIs; verify registry/tag identity before choosing bounds or workarounds. Direct/replicated migration histories remain byte-immutable, and Plan 62/63 behavior remains a regression obligation.

The downstream consumer is mori://tan/tan-app-infrastructure. Preserve artifact fields image, sourceProject, sourcePackage, sourceRevision, upstreamProject, upstreamImplementation, nativePlanSha256 and postgresPlanSha256, with additional direct-plan/qualification detail in the dossier. Validate version-qualified upstream identity against released source and both build paths. Local OCI index/configuration hashes and prepared artifacts never substitute for verified registry publication.

Revision note, 2026-11-13: The user selected Nix-native ClickHouse/Keeper for day-to-day work while retaining the production-version fixture for major qualification. Commands and fixture scope above reflect that split.
