---
type: Guide
title: "Measure pipeline capacity"
description: "Measure pipeline outage and recovery capacity, size a finite storage budget, and set alerts from the recorded workload."
docId: DOC-2
tags: ["capacity", "backpressure", "recovery", "operations"]
generated:
  by: process:codex
  at: "2026-10-16T05:27:26Z"
---

# Measure pipeline capacity

Run `nix develop -c just outage-acceptance` on the intended deployment hardware before choosing
an ingest envelope. The launcher builds the packaged server, creates disposable credentials,
and owns PostgreSQL, ClickHouse and a loopback outage proxy. It never uses an ambient database.
Its default proof schedules 200 events/s for 600 seconds, restarts the server while the breaker
is open, verifies paused source reads and zero valid archives, then checks the acceptance ledger
and canonical analytical count. `just outage-smoke` uses 40 seconds for development.

The mixed producer workload targets about 768 bytes/event with compressible padding (the
recorded identify sample is 770 bytes): one account, 6000 synthetic users and source-scoped
sessions, with 20 events/session. It includes identify v2, identify_once v1, page views and
payments; every event carries a URL/campaign and device identifier, and HTTP user-agent
classification runs before private queue-v2 persistence. The full run verifies 120000 enriched
session events and 12000 governed trait operations. This exercises the final projections,
durability and drain capacity; realistic payload distributions and analytical query contention
still need deployment-specific measurements. Settings are writer batch 5000, adapter batch
1000, inbox 1, ready-batch buffer 1, prefetch disabled, visibility 60 seconds, probe 5 seconds,
insert deadline 30 seconds, flush latency 100 ms and default credential admission 2000/s with
burst 10000. The 100 ms flush setting differs from production's default 5000 ms; include
that extra latency when choosing response/recovery expectations for another configuration.

Reports remain private in `.dev/acceptance/outage-*/report.json`; they record hardware,
parameters, acceptance/new-queue/write counters, queue age, database growth, generated WAL,
ClickHouse part bytes, first write and drain times. A separate 5000-event blocked calibration
includes probe startup in its conservative drain capacity. The long run must finish within
`68 + 1.5 * backlog / (calibrated_capacity - 200)` seconds after recovery; first write must
finish within 68 seconds (probe, visibility and scheduling/flush tolerance). Actual logical
count equality and queue emptiness are required, not just an increase in the writer counter.

## Final development measurement, 2026-10-16

Apple M1 Max, 64 GiB RAM, arm64 macOS 26.7; local native PostgreSQL and ClickHouse 26.8.2.7
on a shared development workstation. The packaged server passed the full owned run without
other build/test load from this task. Other deployment or reference hardware remains
unmeasured; repeat this procedure there before assigning its budget. This replaces the earlier
small v1-style capacity workload; it does not extrapolate that older drain result to new writes.

| Measurement | Result |
| --- | ---: |
| Actual storage outage | 600.004 s |
| Wire accepted / newly queued / logical writes | 120000 / 120000 / 120000 |
| Accepted and newly queued rate | 200.00 events/s |
| Writes while blocked | 0 |
| Oldest backlog at recovery | 600.66 s |
| First recovered write | 4.65 s |
| Full backlog drain | 40.82 s |
| Logical drain rate | 2939.58 events/s |
| Successful writer counter / rate during drain | 120800 / 2959.18 events/s |
| Conservative 5000-event calibration capacity | 810.51 events/s |
| Accepted drain bound | 362.83 s |
| PostgreSQL database growth | 212238336 bytes (1768.65/event) |
| Generated WAL | 547020800 bytes (4558.51/event) |
| Active ClickHouse part bytes at finish | 9949230 |
| Enriched events with nonempty sessions | 120000 |
| Governed trait operations | 12000 |
| Valid archived events | 0 |

Reads stayed at 200 before restart and 7200 afterward while the backlog grew to 120000.
The successful writer counter exceeds logical writes because leased buffered deliveries can be
retried; exact canonical reads remain 120000. The counter measures successful insert payloads,
not unique events. Private evidence is `.dev/acceptance/outage-ni1sty8k/report.json`
(one non-skipped Hspec example).

For **10 GiB reserved disk, 50% usable headroom, 200 new events/s**, the measured
database-plus-generated-WAL cost gives approximately **4243 seconds (1.18 hours)** before
that budget is consumed. At that horizon, conservative spare capacity is
610.51 events/s and the projected backlog would take about
1390 seconds to drain with continued 200/s input. This is an extrapolation, not a tested
outage duration. The actual exercised outage is ten minutes, with producer traffic stopped
at recovery; continued-arrival drain must be validated for the target workload.

## Size a finite outage budget

Let `r` be admitted new events/s, `q` measured PostgreSQL queue-plus-ledger bytes/event, `w`
generated WAL bytes/event, `D` disk reserved for this outage and `h` the usable fraction after
headroom. A conservative shared-volume estimate with no WAL recycling is:

```text
outage_seconds <= h * D / (r * (q + w))
backlog_events = r * outage_seconds
recovery_seconds ~= backlog_events / (measured_write_capacity - ongoing_new_event_rate)
```

The denominator must be positive. WAL replication/retention, table/index bloat, checkpoints,
quarantine, payload size, other workloads and the permanently retained acceptance ledger
change this budget. Generated WAL is traffic, not measured persistent WAL disk; the formula
conservatively assumes it remains retained. Measure each volume separately when they differ.
Reserve additional ClickHouse ingest/merge disk after recovery. This estimate is a planning
limit for a stated workload, not a promise of arbitrary outage recovery.

## Alert before capacity is exhausted

Alert on breaker state 1 or 2 lasting more than two probe intervals, any unexplained archive
increase, sustained queue growth or oldest age above 60 seconds. Escalate before projected
remaining disk time falls below recovery time plus the operator response budget; use at least
50% capacity headroom until repeat measurements justify another value. The default readiness
queue threshold is 100000 events and stale-flush threshold 120 seconds; at 200 new events/s,
100000 queued events represent about 500 seconds of outage. Readiness is a traffic-placement
signal, not disk protection. Rate limits are per credential per process, so total admitted
traffic across credentials/processes must fit the measured deployment envelope.

[Operations](operations.md) · [Configuration](configuration.md)
