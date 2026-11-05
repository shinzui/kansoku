---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

- [Name the experiment conversion rate measure correctly in the query guide](name-the-experiment-conversion-rate-measure-in-the-query-guide.md) - The query guide says the experiment conversion endpoint returns a measure named rate, while the query compiler and its tests emit conversion_rate; correct the guide so API consumers read the measure kansoku actually returns.
- [Operate Kansoku's ClickHouse schema and maintenance on a shared server](operate-the-clickhouse-schema-on-a-shared-server.md) - Let Kansoku's ClickHouse maintenance ceremony, admin jobs and restore verification work on a ClickHouse server shared with other apps, using tenant-scoped quiesce evidence and on-demand app-database backups instead of server restarts, without reading other users' queries.
- [Create the ingest queue in migrations so the server runs with a DML-only PostgreSQL role](run-the-server-with-a-dml-only-postgresql-role.md) - Move PGMQ queue creation from kansoku-server startup into kansoku-migrate, make startup only verify the queue, and document which role each binary uses, so Kansoku runs on a managed PostgreSQL app database whose runtime role has no DDL rights.

