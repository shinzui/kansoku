# TAN buffering image handoff

Publication is pending final qualification and the established release-owner gate.
There is no new deployment digest yet. Preserve the previous immutable image for
rollback; it restores the previous outage-sensitive startup/readiness behavior.

The intended consumer is mori://tan/tan-app-infrastructure. Its production
application remains Linux amd64 against the independently verified one-shard,
two-replica Altinity target. The final artifact will retain the eight established
fields: image, sourceProject, sourcePackage, sourceRevision, upstreamProject,
upstreamImplementation, nativePlanSha256 and postgresPlanSha256. The native hash
identifies exact replicated-plan stdout bytes; direct-plan qualification remains
separate. Local OCI/configuration/archive hashes are not registry manifest digests.

Keep `/health/live` as liveness and `/health/ready` as admission. Add monitoring
for `/health/pipeline`, including topology-unchecked/unavailable/mismatch/stale
and writer storage failures. Move existing ClickHouse/backlog alerts from
readiness to pipeline health or metrics before rollout. The READY depth and
flush-age environment variable names remain compatible and affect diagnostics.

Serving startup and 202 ingestion depend on PostgreSQL, configuration and the
maintenance fence. ClickHouse delivery can pause while accepted events accumulate.
Size queue, acceptance ledger and retained WAL with reserved disk and headroom;
there is no unbounded buffering guarantee. Drain capacity must exceed continuing
arrival rate. Metric queries may return retryable 503; explicit migration jobs
continue requiring ClickHouse and deliberate maintenance/drain procedures.

Keep the full expected replica UUID inventory and cluster selector. Never lower
quorum or use direct mode to bypass a mismatch. Validate routing, per-replica
storage/fsync, grants, TLS and managed event flow under TAN's deployment process.
Environment selector changes require a rollout retaining the PostgreSQL queue.
This handoff performs no deployment, migration or external notification.
