---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

- [Name the experiment conversion rate measure correctly in the query guide](name-the-experiment-conversion-rate-measure-in-the-query-guide.md) - The query guide says the experiment conversion endpoint returns a measure named rate, while the query compiler and its tests emit conversion_rate; correct the guide so API consumers read the measure kansoku actually returns.
- [Operate Kansoku's ClickHouse schema and maintenance on a shared server](operate-the-clickhouse-schema-on-a-shared-server.md) - Let Kansoku's ClickHouse maintenance ceremony, admin jobs and restore verification work on a ClickHouse server shared with other apps, using tenant-scoped quiesce evidence and on-demand app-database backups instead of server restarts, without reading other users' queries.
- [Create the ingest queue in migrations so the server runs with a DML-only PostgreSQL role](run-the-server-with-a-dml-only-postgresql-role.md) - Move PGMQ queue creation from kansoku-server startup into kansoku-migrate, make startup only verify the queue, and document which role each binary uses, so Kansoku runs on a managed PostgreSQL app database whose runtime role has no DDL rights.
- [Count unique users over a whole query range](count-unique-users-over-a-whole-range.md) - Let the users, custom unique_count and acquisition users measures return one unbucketed answer per group for the whole from..to range, so a consumer can show exact visitors for a period instead of summing daily buckets that count returning users more than once.
- [Attribute conversions to first-touch acquisition](attribute-conversions-to-first-touch-acquisition.md) - Add converted-user and conversion-rate measures to /metrics/acquisition for a caller-supplied list of conversion events, credited to the visitor's first-touch channel, referrer, campaign or landing page, so a consumer can rank traffic sources by how well they convert.
- [Classify AI assistant referrals as their own channel](classify-ai-assistant-referrals-as-a-channel.md) - Add channel rule version 2 with an ai_assistant channel for visits referred by ChatGPT, Perplexity, Claude, Gemini, Copilot and similar assistants, which version 1 splits across organic_search, referral and other.
- [Add a percentile aggregation to custom metrics](add-a-percentile-aggregation-to-custom-metrics.md) - Let /metrics/custom and saved metric definitions compute a percentile (for example p50, p75 or p95) of a declared numeric property, so consumers can report latency-like values such as web vitals and page durations, where averages mislead.
- [Declare client error and web vital events](declare-client-error-and-web-vital-events.md) - Declare client_error and web_vital event schemas in the registry, and ask the browser SDK to capture them, so a consumer can report JavaScript errors and Core Web Vitals by page next to product analytics.
- [Filter and group events by the attributes of their session](filter-and-group-events-by-their-session-attributes.md) - Add session-scoped dimensions (for example session:channel, session:referrer_host, session:utm_campaign, session:entry_page) that page-views, users and custom metrics can filter and group by, selecting each event by the first-touch attributes of the web session it belongs to, so a consumer can report the pages viewed and the people seen during visits from one source.

