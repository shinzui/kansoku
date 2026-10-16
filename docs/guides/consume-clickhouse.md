# Consume ClickHouse from a trusted analytics tool

Use the [HTTP metrics API](query-metrics.md) for account-authorized application traffic.
Direct SQL is an optional trusted single-tenant operator surface. A reader can query every
account in the database; an account predicate is not row-level authorization. Keep database
credentials on the consumer server, and restrict network access to that server.

## Stable projections and reader setup

Apply all numbered ClickHouse migrations with the writer stopped, as described in
[operations](operations.md). Migration 0023 establishes these supported projections:

| View | Ordered columns / purpose |
| --- | --- |
| `analytics.events_resolved` | Exactly `event_id, event_name, occurred_at, url, account_id, canonical_user, properties_json`. |
| `analytics.events_resolved_v3` | The same seven-column contract, with the current conservative identity resolver. |
| `analytics.events_analytics_v1(account=…, from_time=…, to_time=…)` | Those seven columns, followed by `source, source_service, session_id, is_bot, browser_family, os_family, device_class, channel, country_code`. |

The versioned analytical projection takes an account String and UTC DateTime64(3) half-open
bounds. `canonical_user` is `user:<id>`, otherwise `anonymous:<id>`, otherwise empty. Explicit
user IDs win; ambiguous shared signals never choose an arbitrary user. Identity uses currently
retained evidence, so an old event's subject can change after new evidence or applied retention.
`properties_json` is native ClickHouse JSON. Use guarded Dynamic subcolumns, as the recipes do;
string JSON extraction functions do not implement this typed property contract.

Views read canonical retained facts (`FINAL`) before aggregation; physical retries count once.
They become visible after the asynchronous writer commits, with no fixed freshness promise.
SQL results are exact for their stated population; internal sketch/rollup/evidence tables and
connection-private HTTP identity caches are not stable interfaces and receive no reader grants.

Apply [reader-role.sql](../../db/clickhouse/reader-role.sql) as the migration/view owner, then
create a dedicated password user with `DEFAULT ROLE kansoku_reader`. Use an interactive secret
input or your secret manager; do not commit a password or put it in shared shell history.
The ClickHouse operator configuration must enable `access_management` for the authenticated
migration user and set `access_control_path` to a writable operator-owned directory. These
are ClickHouse server/user settings; the embedded local-development default is not an SQL
access-management deployment configuration.
The owner must retain access to underlying objects: these views deliberately use SQL SECURITY
DEFINER with the migration operator as definer. Verify owner identity on every deployment.
For example, run the role file through the operator's configured client:

```bash
clickhouse-client --multiquery < db/clickhouse/reader-role.sql
```

Create the user using private operator SQL (a mode-0600 file or secret-manager input):

```sql
CREATE USER kansoku_dashboard IDENTIFIED WITH sha256_password BY 'PRIVATE_READER_PASSWORD'
DEFAULT ROLE kansoku_reader;
```

The role grants SELECT only on the three views. It cannot read raw facts/identity evidence or
write data. It fixes readonly=2, a 30-second maximum query time, 512 MiB maximum memory,
10,000 result rows and 10 MiB result bytes, throwing on overflow. Native result limits are
checked at block boundaries and can overshoot within a block; this is not HTTP's strict
complete-or-error 10,000-point contract. Clients may lower time/memory within positive bounds.
The profile fixes ISO UTC JSON datetime output, including `Z`, and four threads.

Direct SQL does not acquire the PostgreSQL HTTP maintenance fence. Pause external query
schedules during erasure/retention/rebuilds, and resume after the administrative job's completed
receipt. A query racing maintenance has no atomic cross-table snapshot guarantee. External
caches, exports and downstream copies need their own deletion/retention procedures.

## Recipes that match HTTP

Executable queries live in [db/clickhouse/recipes](../../db/clickhouse/recipes). Supply native
parameters `account`, `from_time`, `to_time`, and `source_service` to your ClickHouse client;
use a bounded interval and source service. The recipes intentionally cover these exact cases:

| Recipe | Matching HTTP request / population |
| --- | --- |
| `daily-users.sql` | `/metrics/users?timeGrain=day&window=calendar`, same source-service filter; nonempty subjects, profile events excluded, bots excluded. `to` must be at or before today's UTC date. |
| `revenue-by-plan.sql` | `/metrics/revenue?timeGrain=day&groupBy=prop:plan`, same source-service filter; bots included, guarded finite numeric amount, absent/incompatible plan = null, empty string remains empty. |
| `two-step-funnel.sql` | `/metrics/funnel?steps=…&window=…&mode=sequential&measure=count`, same source-service filter; bots included, no exclusions/grouping, exact subject counts. |

For the funnel also supply `first_step`, `second_step`, and positive `window_seconds` (at most
7,776,000). Ordering is `(occurred_at,event_id)`; one event cannot supply both steps even when
names repeat. Use HTTP for strict/any-order modes, selected-chain timing, exclusions, traits,
whole-session attribution and rolling/cohort metrics. These recipes do not claim those semantics.

Revenue is an analytical Float64 sum of `payment_completed.amount` in one declared account
currency/unit. Normalize producer amounts to that unit. It performs no FX conversion, refund
or net-revenue accounting and is not an exact monetary ledger. Feature adoption is a distinct
subject count, not a percentage without a separately defined eligible denominator.

## Grafana

Verified consumer: Grafana OSS **13.2.4**, official `grafana-clickhouse-datasource` **4.22.1**.
Install that plugin on the Grafana server. Import
[datasource.json](../examples/grafana/datasource.json), replacing host, port, reader username
and the private password. It uses the HTTP protocol, a 25-second query timeout and an explicit `max_execution_time=30`
custom setting. The pinned Go driver derives a server timeout from its context deadline plus
five seconds, overriding connection settings; the shorter consumer deadline fits the reader
profile without weakening its 30-second ceiling. Import
[dashboard.json](../examples/grafana/dashboard.json) after replacing its `rawSql` placeholder
with `daily-users.sql` rendered with your literal account, source and UTC interval. Render
literals safely in trusted configuration; never concatenate dashboard viewer input into SQL.
The panel uses table format 1 and datasource UID `kansoku-reader`.

The executable acceptance imports the datasource and dashboard into an owned Grafana server,
checks plugin health, reads the saved target and executes it through `/api/ds/query`, comparing
the answer with the constrained reader and HTTP. Metabase may be configured with a compatible
ClickHouse driver and the same role, but is an example integration, not a verified version claim.

## GrowthBook assignments and facts

Verified consumer: GrowthBook **5.1.0**, upstream tag commit
`7cbc85d1d113595757f6808b5c440657e4325b47`. Configure its ClickHouse datasource with the
reader credentials and `maxExecutionTime: 30`. Configure the identifier as `user_id`.

Use `growthbook-assignments.sql` with an additional `experiment` parameter. Its output is
`user_id, timestamp, experiment_id, variation_id`. Edit the explicit mapping
`control → '0', variant_b → '1'` to match that experiment's configured variation indexes;
unmapped variants fail instead of silently joining a wrong variation. Keep every distinct
canonical exposure, including repeated identical assignment tuples with different event IDs.
Use `growthbook-payment-facts.sql` for `user_id, timestamp, amount`, with the same account,
source, interval and canonical subject convention. Invalid historical amounts are omitted.
Timestamps stay DateTime64(3,'UTC'); the reader profile renders JSON with explicit UTC offsets.

These are row-level inputs, not experiment results. Kansoku's approximate exposure counts
measure raw identities; exact diagnostics show contamination and exclusive earliest assignment
shares. Re-exposures/multiple variants need the consumer's documented assignment policy.
Aggregate conversion counts alone are not sufficient statistics for every experiment method;
no significance or causal claim follows from these recipes.

The real consumer acceptance calls upstream connection and query-editor schema/sample methods
for both queries and checks timestamps in a non-UTC process. It starts no GrowthBook app
state database and performs no statistics-engine calculation. The unmodified adapter uses its
upstream TypeScript/Node settings, not a substituted SQL parser or mock.

[Reproduce consumer acceptance](consumer-conformance.md) · [Query metrics](query-metrics.md) · [Operations](operations.md)
