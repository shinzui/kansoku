# Measure pipeline capacity

Run `nix develop -c just outage-acceptance` on the intended deployment hardware before choosing
an ingest envelope. The launcher builds the packaged server, creates disposable credentials,
and owns PostgreSQL, ClickHouse and a loopback outage proxy. It never uses an ambient database.
Its default proof schedules 200 events/s for 600 seconds, restarts the server while the breaker
is open, verifies paused source reads and zero valid archives, then checks the acceptance ledger
and canonical analytical count. `just outage-smoke` uses 40 seconds for development.

The fixed producer event is approximately 512 bytes with compressible padding, one account,
one synthetic user and low-cardinality properties. This exercises durability and drain capacity;
measure realistic payload distributions and analytical query contention separately. Settings are writer batch 5000, adapter
batch 1000, inbox 1, ready-batch buffer 1, prefetch disabled, visibility 60 seconds, probe 5 seconds, insert deadline
30 seconds, flush latency 100 ms and default credential admission 2000/s with burst 10000.
The benchmark's 100 ms flush setting differs from the production default of 5000 ms; include
that extra latency when choosing response/recovery expectations for another configuration.

Reports remain private in `.dev/acceptance/outage-*/report.json`; they record hardware,
parameters, acceptance/new-queue/write counters, queue age, database growth, generated WAL,
ClickHouse part bytes, first write and drain times. A separate 5000-event blocked calibration
includes probe startup in its conservative drain capacity. The long run must finish within
`68 + 1.5 * backlog / (calibrated_capacity - 200)` seconds after recovery; first write must
finish within 68 seconds (probe, visibility and scheduling/flush tolerance). Actual logical
count equality and queue emptiness are required, not just an increase in the writer counter.

## Development measurement, 2026-10-15

Apple M1 Max, 64 GiB RAM, arm64 macOS 26.7; local native PostgreSQL and ClickHouse on a shared
development workstation. The packaged server passed the full owned run. Other deployment or
reference hardware remains unmeasured; repeat this procedure there before assigning its budget.
The separate acceptance suite ran during the blocked interval, after calibration and before drain.

| Measurement | Result |
| --- | ---: |
| Actual storage outage | 600.005 s |
| Wire accepted / newly queued / logical writes | 120000 / 120000 / 120000 |
| Accepted and newly queued rate | 200.00 events/s |
| Writes while blocked | 0 |
| Oldest backlog at recovery | 600.17 s |
| First recovered write | 2.48 s |
| Full backlog drain | 21.21 s |
| Logical drain rate | 5657.44 events/s |
| Successful writer counter / rate during drain | 121049 / 5706.89 events/s |
| Conservative 5000-event calibration capacity | 870.94 events/s |
| Accepted drain bound | 336.28 s |
| PostgreSQL database growth | 146194432 bytes (1218.29/event) |
| Generated WAL | 416709088 bytes (3472.58/event) |
| Active ClickHouse part bytes at finish | 3031810 |
| Valid archived events | 0 |

Reads stayed at 200 before restart and 7200 afterward while the backlog grew to 120000. The
successful writer counter exceeds logical writes because leased buffered deliveries can be
retried; exact canonical reads remain 120000. Thus the counter measures successful insert
payloads, not unique events. Private source evidence is
`.dev/acceptance/outage-mk1fy7bw/report.json` (one non-skipped Hspec example).

As an illustrative conservative budget for **10 GiB reserved disk, 50% usable headroom,
200 new events/s**, the measured database-plus-generated-WAL cost gives about **5723 seconds
(1.59 hours)** before that budget is consumed. At that horizon, the conservative spare
capacity is 670.94 events/s; the resulting backlog
would take about 1706 seconds to drain with
continued 200/s input. This extrapolation is not a tested outage duration. The actual exercised
outage is ten minutes, with producer traffic stopped at recovery; continued-arrival drain must
be validated for the target workload. Use the model below with actual reserved disk and payloads.

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
