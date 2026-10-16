---
type: Review
title: Kansoku initial release implementation correctness
description: >-
  Requests changes for an accepted JSON payload that parks the shared writer,
  organization trait filters that create unusable cohorts, and database errors
  that disclose filter values in application logs; the packaged acceptance gate
  also fails because its scenarios share leftover cohort fixtures.
generated:
  by: process:codex
  at: "2026-10-16T18:12:01Z"
reviewId: REV-2
subject: mori://shinzui/kansoku
subjectKind: project
reviewedSha: 138d9a316931bbf46781757a29ab6c7fdd90f870
coverage: incremental
baseSha: 98c61c9d9de8f2c548e972873fe7b3bfc9ee2953
previousReview: REV-1
reviewedAt: "2026-10-16T17:15:21Z"
reviewerKind: model
reviewer: process:codex
provider: openai
model: gpt-6
effort: unspecified
outcome: changes-requested
dimensions:
  - correctness
  - security
  - test-coverage
  - operability
  - documentation
context: >-
  Reviews the expanded implementation after REV-1, treating its findings as addressed.
  Examined ingestion validation and immutable acceptance, writer recovery, query execution,
  identity cache preparation, cohort and custom metric compilers, organization aggregation,
  session and funnel composition, administrative fencing and rebuilds, migrations, tests,
  and release commands. Ran the locked deterministic gate, organization acceptance,
  packaged acceptance, and targeted HTTP/native probes on disposable PostgreSQL and
  ClickHouse instances. Packaged acceptance failed in the second telemetry-mode cohort
  scenario before reaching the later reader and administrative families.
  The working tree was clean at the reviewed commit. This is an implementation review,
  not a renewed competitor comparison or a new capacity benchmark. Reasoning effort was
  not exposed in the session metadata.
---

# Kansoku initial release implementation correctness

**Release recommendation: changes requested.** An accepted event can permanently park the
shared writer until an operator intervenes. Two further defects affect the new cohort
composition and the privacy of database-error logging. All three findings are grounded in
the current implementation. A fourth finding explains why the packaged acceptance gate
fails. The earlier review's feature requests are not reopened.

Priority P1 means fix before release because ordinary producer input can stop processing.
Priority P2 means a supported operation fails or violates an established boundary and should
also be corrected before calling the initial implementation ready.

## F1 Accepted JSON can park the writer for every account

**P1 — correctness, availability, operability.**

[Event validation](../../kansoku-api/src/Kansoku/Event/Validation.hs), lines 46–65, accepts
arbitrary `properties` and `context` objects without checking their compatibility with the
materialized native JSON columns. Valid JSON is not sufficient for that compatibility.
For example, this object has distinct JSON keys but overlapping flattened ClickHouse paths:

```json
{"a.b": 1, "a": {"b": 2}}
```

[Migration 9](../../db/clickhouse/migrations/0009_typed_properties.sql) materializes
`CAST(properties, 'JSON')`; the context projection introduced by
[migration 19](../../db/clickhouse/migrations/0019_web_enrichment.sql) uses the same kind of
conversion. ClickHouse 26.8.2 rejects the example with code 117, `INCORRECT_DATA`, and
`Duplicate path found during parsing JSON object: a.b`.

The HTTP boundary nevertheless commits its acceptance identity and queue message and
returns 202. [Writer recovery](../../kansoku-core/src/Kansoku/Writer/Recovery.hs), lines
120–141 and 156–162, classifies the database exception as `Parked`, stops pulling the queue,
and retries the same deterministic failure indefinitely. A healthy storage probe cannot
make the payload insertable. The queue and writer are shared across accounts.

**Reproduction.** On a fresh migrated disposable stack, submit a valid baseline event and
wait until it is written. Then submit this batch with a write key:

```json
[
  {
    "eventId": "review-json-collision",
    "eventName": "review_event",
    "source": "web",
    "occurredAt": "2026-07-01T00:00:00Z",
    "receivedAt": "2026-07-01T00:00:00Z",
    "userId": "review-user",
    "properties": {"a.b": 1, "a": {"b": 2}},
    "context": {}
  }
]
```

The observed response was `202 {"accepted":1,"rejected":[]}`. After the breaker entered
state 2, a valid event for a second account also received 202. After another retry interval:

```text
kansoku_writer_breaker_state 2.0
kansoku_writer_insert_failures_total 2.0
kansoku_writer_events_written_total 1.0
```

The second account's `/metrics/events` response still had an empty `points` array. The
baseline was the only written event. This is durable backlog and blocked processing, not
evidence that accepted queue messages were deleted.

**Required correction.** Make accepted objects compatible with the actual storage
representation before claiming their event IDs, or use a representation that preserves
these objects without a failing materialization. Handle both properties and context,
including nested objects and arrays. If the supported input contract excludes ambiguous
paths, return a permanent indexed validation rejection. Preserve storage-outage recovery;
simply discarding every database exception would reintroduce silent loss.

**Acceptance condition.** An HTTP batch containing one incompatible object and one valid
event has the documented rejection/preservation behavior, and subsequent valid events for
another account are written. Repeat for single and beacon transports, context objects,
retries, and replayable legacy input. Verify that ordinary database outages still pause and
recover without discarding accepted events.

## F2 Organization trait conditions produce unusable saved cohorts

**P2 — correctness.**

[Cohort validation](../../kansoku-core/src/Kansoku/Cohort/Query.hs), lines 18–28, rejects
`user:` dimensions inside event conditions but passes `org:` dimensions to the shared
dimension compiler. The latter accepts governed organization traits such as `org:plan`.
Creation therefore succeeds.

The condition compiler in the same file, lines 52–61, reads directly from
`analytics.events_resolved_http`. It does not attach `Traits.organizationSource`, although
the compiled predicate references `org_trait_plan`. That column exists only after the
organization-trait join. Member queries and every metric using the cohort fail at execution.

**Reproduction.** With service-token authentication, create:

```json
{
  "name": "organizations-on-pro",
  "kind": "behavioural",
  "conditions": [
    {
      "did": "feature_used",
      "withinDays": 30,
      "filters": [{"dimension": "org:plan", "op": "eq", "value": "pro"}]
    }
  ]
}
```

Observed results on the disposable stack:

| Operation | Result |
| --- | --- |
| `POST /cohorts` | 200 and a persisted definition |
| `GET /cohorts/{id}/size?from=2026-07-01&to=2026-07-03` | 503 `clickhouse_unavailable` |
| `GET /metrics/users` over that range with `filter=cohort:eq:{id}` | 503 `clickhouse_unavailable` |
| Direct `/metrics/users` with `filter=org:plan:eq:pro` | 200, correctly counting both fixture users |

The native exception was code 47: `Unknown expression or function identifier org_trait_plan`.
The storage service was healthy. Repeating the saved query cannot resolve this error.

**Required correction.** Attach the governed organization-trait projection in cohort
condition populations, including dimensions inside OR terms, or explicitly reject this
combination during definition validation if it is outside the supported cohort contract.
Do not persist a definition that can only produce a retryable storage error.

**Acceptance condition.** Exercise create/update, member size/pages, and metric cohort
selection with `org:plan` and `org:seats` conditions. Assert exact populations, account
isolation, current-trait updates and OR behavior, or assert the documented permanent
validation error before persistence.

## F3 Database errors disclose bound filter values in application logs

**P2 — security and operability.**

[Query execution](../../kansoku-core/src/Kansoku/Metrics/Query.hs), lines 618–621, puts
`show err` into `QueryStorageFailure` for native exceptions other than three resource-limit
codes. [The metrics handler](../../kansoku-core/src/Kansoku/Metrics/Handler.hs), lines
350–368, writes that whole value to stderr.

ClickHouse's native exception contains the analyzed SQL with bound values expanded. The
F2 reproduction therefore wrote the account, event name, date range and organization-plan
operand into a JSON application error record, including a native stack trace. Parameterized
SQL protects query construction but does not redact exception messages. Safe access-log and
span middleware cannot remove this separate application log record.

**Reproduction.** Use the F2 cohort definition with the unique operand
`private_review_filter_6a91`, query it through `/metrics/users`, and inspect the server's
stderr log. The public response remains the generic 503; the underlying error log includes
the operand in the expanded `org_trait_plan = ...` predicate. The ordinary query privacy
checks exercise successful queries and do not cover this native-error branch.

**Required correction.** Classify errors into safe structured fields such as backend, native
numeric code and a correlation identifier. Keep raw native messages, expanded SQL and
arbitrary exception text out of routine application logs. Apply the same rule to the
outer exception branch at handler line 354.

**Acceptance condition.** Trigger a native database failure with unique private sentinels
in both request filters and saved-definition filters. Assert their absence from the complete
stderr/access/span output while retaining a useful error classification and generic public
problem response. This boundary must remain safe even after F2 is fixed.

## F4 Shared cohort fixtures break packaged acceptance

**P2 — test coverage and release verification.**

`nix develop -c just acceptance` exits 1 in the second telemetry mode at
[cohort acceptance](../../scripts/cohorts_acceptance.py), line 148:

```python
assert walk()==walk(True)==sorted([ident,traits['id'],sid])
```

[The aggregate runner](../../scripts/acceptance.py), lines 271–292, reuses one account and
database across the three modes. After the first cohort scenario cleans up its definitions,
the custom-metrics scenario creates a static cohort at
[custom metric acceptance](../../scripts/custom_metrics_acceptance.py), lines 88–89, and
leaves it in the account. Its final cleanup only deletes a metric definition. The next
cohort scenario walks the account's complete list and compares it with exactly its own
three UUIDs, so the retained static cohort makes the assertion fail.

The run passed its first cohort and custom-metrics scenarios, then failed at this exact
assertion in the second mode. A standalone probe then ran the custom-metrics scenario to
completion and found exactly one static cohort left in the account. This finding concerns
fixture isolation; it is not evidence that production pagination is incorrect.

**Required correction.** Give each scenario ownership of a separate account or reliably
clean up every resource it creates, including static membership and dependent definitions.
Keep the bidirectional pagination assertion meaningful rather than removing it.

**Acceptance condition.** The unmodified `just acceptance` command passes all three modes
and reaches its final reader and packaged administrative families on fresh disposable stores.

## Verification and release scope

- `nix develop -c just check` passed: 380 deterministic core examples, 21 client examples,
  four probe tests, three telemetry modes with seven examples each, telemetry lifecycle
  cases, formatting, generated contracts/OpenAPI, lint and the configured documentation gates.
  The OpenAPI linter passed with warnings and informational diagnostics.
- `nix develop -c just organizations-acceptance` passed, including native tests and public
  replay, member funnels, retention, traits, attribution, validation and account isolation.
- Targeted probes used the built executables and owned PostgreSQL/ClickHouse instances with
  all 25 ClickHouse migrations. Organization aggregation with positive, negative and
  person-trait cohorts and session cohort selection worked in the control cases.
- `nix develop -c just acceptance` failed as described in F4. Before failure it passed the
  packaged Nix build, all 455 live core examples, four probe tests, native recovery,
  resource limits, replay and identity checks, 57 Hurl requests, 22 live client examples,
  and the first mode's public analytics/cohort/custom-metric scenarios. The later reader
  and packaged administration scenarios did not run, and this is not a passing release gate.
- `nix develop -c just reviews-check` validates the new review and its bundle log.

The release decision rests on the confirmed failures above even when the existing suites
pass. After corrections, add regression coverage at the HTTP/native boundary and rerun the
deterministic, packaged and organization gates. The separate required browser SDK and real
Grafana/GrowthBook consumer mode in [consumer conformance](../guides/consumer-conformance.md)
also remains part of release verification; this review does not claim a fresh run of that
external-consumer mode, the ten-million-row benchmarks or the long outage proof.

This review changes documentation only. It does not implement the corrections or publish a
release.

## Implementation follow-up — 2026-10-16

F1 is resolved by [EP-46](../plans/46-reject-storage-incompatible-json-before-acceptance.md),
implemented in `e5af95f`. Pure shared validation rejects duplicate non-null flattened paths in
properties and context before new acceptance claims. Native parity covers 21 shapes in both
materialized columns. Public single, batch and beacon proofs exercise 48 permanent rejections,
154 valid canonical events, corrected-ID reuse, immutable retries, raw/native values and
second-account progress after each incompatible submission. The first-release scope confirmed
that no historical accepted queue exists; no legacy-input migration is required. The packaged
outage smoke passed 8,000 accepted events through storage failure and writer restart with zero
valid archives; recovery and acknowledgement code is unchanged.

F4 is resolved by [EP-48](../plans/48-clean-acceptance-fixtures-across-telemetry-modes.md) in the
same implementation. Scenario-owned cleanup preserves exact pagination, clears static members
before deleting definitions, releases foreign resources and runs on injected failure. The
required composition verifies repeated baselines and continued cleanup without deleting an
unrelated resource. `nix develop -c just acceptance` now exits zero, passing 523 core examples,
four probes, 22 live client examples, all three telemetry modes, reader parity and all seven
administrative families. Private evidence is `.dev/acceptance/run-1szhsbva/`; the packaged
outage report is `.dev/acceptance/outage-kthl2ca1/report.json`. `just check` also exits zero.

This follow-up records implementation acceptance evidence, not a new independent review or
release approval. F2 and F3 remain outside this repair. The separate external browser/consumer
configuration, long outage proof and capacity benchmarks were not rerun here.
