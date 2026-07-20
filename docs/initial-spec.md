# 観測（Kansoku） — Product and Web Analytics Service

> **Status: product vision, not an API reference.** This document preserves Kansoku's product
> thesis and longer-term direction. For shipped behavior, start at the
> [documentation index](README.md), then use the generated [OpenAPI document](api/openapi.json)
> and [event schema catalog](contracts/events.json). Sections phrased as “should” are
> aspirational unless a current guide says otherwise.

## Name

**観測（かんそく / Kansoku）** means **observation**.

The name fits the purpose of the service: it observes how users, applications, services, campaigns, and systems behave over time. The goal is not only to track clicks, but to understand what is happening across a product and its supporting infrastructure.

Kansoku is the observation layer for modern applications.

## Purpose

Kansoku is a first-party analytics service for:

* product analytics
* web analytics
* server-side analytics
* campaign and attribution analytics
* business-event analytics
* observability for user and system behavior

The service is designed to answer questions like:

* Are users activating?
* Which features are most engaging?
* Which acquisition channels convert?
* How do users move through the product?
* Where are users dropping off?
* Which experiments improve conversion?
* What business events occur most frequently?
* How do backend events correlate with user behavior?

## Core Principle

Client-side analytics tells us what users attempted or interacted with.

Server-side analytics tells us what actually happened.

Kansoku supports both.

## High-Level Architecture

```txt
Frontend SDK
Backend services
Workers/importers
Email/webhook processors
Agent systems
        |
        v
Authenticated Kansoku ingestion API
        |
        v
PostgreSQL PGMQ durable queue
        |
        v
Kansoku writer
        |
        v
ClickHouse
        |
        +--> raw events
        +--> materialized views
        +--> rollups
        |
        v
Kansoku query API
        |
        +--> dashboards
        +--> product UI widgets
        +--> reports
        +--> summaries
```

## Event Sources

Kansoku should accept events from multiple sources.

### Browser / Web SDK

Used for:

* page views
* sessions
* CTA clicks
* landing-page attribution
* signup flow behavior
* form starts/submissions
* referrer and UTM tracking

### Product Frontend

Used for:

* UI interactions
* search usage
* filters applied
* feature usage
* dashboard engagement
* activity stream interactions
* onboarding progress

### Backend Microservices

Used for authoritative product analytics.

Examples:

* user registered
* user authenticated
* organization created
* subscription started
* subscription renewed
* payment completed
* checkout abandoned
* search performed
* document created
* invitation accepted
* notification delivered

### Workers and Importers

Used for:

* import completed
* background job completed
* record matched
* batch processed
* enrichment completed
* sync completed
* data quality issue detected

### Email and Campaign Systems

Used for:

* email sent
* email opened
* email clicked
* email bounced
* invitation delivered
* campaign conversion

## Canonical Event Model

The implemented wire type is `AnalyticsEvent` in the generated
[OpenAPI document](api/openapi.json). Its required fields are `eventId`, `eventName`, `source`,
`occurredAt`, `receivedAt`, `properties`, and `context`. It also supports schema versions,
campaign and causation fields, organization and session IDs, and an `identifiers` map for the
closed signal set `cookie`, `device`, `fingerprint`, and `email_sha256`.

Ingestion replaces `receivedAt` with server time and replaces any caller-supplied `accountId`
with the account authenticated by the write key or service token. Declared event property shapes
are immutable, versioned contracts published in the [event schema catalog](contracts/events.json).
See [Send events](guides/send-events.md) for a complete current payload.

## Ingestion Modes

### 1. HTTP Ingestion

Simple path for clients and services.

```txt
POST /v1/events
POST /v1/batch
```

Best for:

* frontend SDKs
* landing pages
* simple backend emitters
* low-risk events

### 2. Event Bus / Outbox Ingestion

Preferred path for important business events.

```txt
domain event committed
        |
        v
integration event emitted
        |
        v
Kansoku projection consumes event
        |
        v
ClickHouse analytics event
```

Best for:

* account lifecycle events
* registration events
* billing events
* authorization events
* collaboration events
* notification events
* import/export events
* workflow state changes

This ensures analytics reflects committed system facts, not just attempted actions.

## ClickHouse Storage

### Raw Events Table

Kansoku stores accepted events in:

```sql
analytics.events_raw
```

The table is a partitioned `ReplacingMergeTree` whose event-ID key makes at-least-once queue
delivery idempotent. `account_id` leads metric isolation, and accepted rows retain their effective
schema version. The ClickHouse migrations under `db/clickhouse/migrations/`—not this vision
document—are the schema source of truth.

## Derived Tables and Rollups

Use ClickHouse materialized views for common metrics.

The current schema materializes daily and weekly active-user states, page views by route,
identity evidence/conflicts, and experiment exposures. Other metrics read raw or
identity-resolved events at query time. See [Query metrics](guides/query-metrics.md) for the live
endpoint and accuracy map.

## Identity Stitching

Kansoku should support anonymous and known users.

Before login:

```txt
anonymous_id
session_id
```

After login:

```txt
anonymous_id -> user_id -> account_id / organization_id
```

Identity events:

```txt
identify
alias
group
```

Current resolution uses account-scoped evidence from cookies, device IDs, hashed email, and
lower-confidence fingerprints. Explicit `userId` wins; otherwise matching signals are ranked by
confidence and recency, with the event's anonymous cookie as fallback. Conflicts remain
queryable, and exact user metrics resolve identity at query time. See
[Send events](guides/send-events.md#identity) and the
[identity deletion runbook](runbooks/identity-data-deletion.md).

## Semantic Metrics Layer

Kansoku should support reusable semantic metrics so applications do not need to query raw events directly.

Examples:

* Active Users
* New Users
* Returning Users
* Conversion Rate
* Activation Rate
* Retention
* Feature Adoption
* Revenue
* Search Success Rate
* Funnel Completion Rate

A metric definition should specify:

```ts
type MetricDefinition = {
  name: string
  description?: string
  eventNames: string[]
  aggregation: "count" | "unique_count" | "sum" | "average" | "ratio"
  filters?: Record<string, unknown>
  groupBy?: string[]
  timeGrain?: "hour" | "day" | "week" | "month"
}
```

The semantic layer keeps analytics consistent across dashboards, reports, product UI, and automated summaries.

## Query API

Kansoku should expose typed APIs instead of arbitrary SQL.

Current implemented endpoints:

```txt
GET /metrics/events
GET /metrics/page-views
GET /metrics/sessions
GET /metrics/funnel
GET /metrics/retention
GET /metrics/feature-adoption
GET /metrics/conversion
GET /metrics/users
GET /metrics/revenue
GET /metrics/experiments
GET /metrics/experiments/conversion
GET /metrics/experiments/funnel
```

`/metrics/acquisition`, `/metrics/organizations`, and `/metrics/custom` are present as contract
placeholders but return `not_implemented`. The goal remains to expose useful product and business
metrics without becoming a generic BI tool.

## Initial Product Metrics

### Activation

Track:

* account created
* email verified
* first login
* onboarding completed
* first meaningful action

### Engagement

Track:

* daily active users
* weekly active users
* feature adoption
* session duration
* repeat visits
* search usage
* document creation
* collaboration events

### Conversion

Track:

* landing page viewed
* CTA clicked
* signup started
* signup completed
* onboarding completed
* subscription started
* purchase completed

### Reliability and Workflow Metrics

Track:

* background job completed
* background job failed
* import completed
* import failed
* notification delivered
* notification failed
* webhook received
* webhook processed
* sync completed
* sync failed

## Web Analytics

Kansoku should replace the need for third-party web analytics where possible.

Track:

* page views
* sessions
* referrers
* UTM attribution
* landing pages
* outbound clicks
* signup funnel
* campaign performance
* device/browser context

Because this is first-party analytics, it can be connected directly to product, account, organization, and business-event data.

## Service Responsibilities

Kansoku owns:

* event ingestion
* event validation
* event schema registry
* identity stitching
* ClickHouse writes
* raw event storage
* materialized views
* rollups
* semantic metrics
* analytics query API
* product metrics
* web analytics
* campaign analytics
* analytics summaries
* reporting
* reusable metrics

Kansoku does not own:

* business workflows
* user source of truth
* account source of truth
* organization source of truth
* billing source of truth
* email sending
* authorization source of truth
* CRM state

Other services emit facts. Kansoku observes them.

## Open Source Shape

Kansoku should be useful outside any single company or product.

The open source project should provide:

* event ingestion server
* browser SDK
* server SDKs
* ClickHouse schema
* ClickHouse writer
* query API
* semantic metrics layer
* basic dashboard endpoints
* schema registry
* identity stitching
* deployment examples

Kansoku is designed to be useful for SaaS products, internal business applications, marketplaces, developer tools, and consumer applications.

The core project provides generic analytics infrastructure. Product-specific metrics should be implemented by applications built on top of Kansoku.

## Current Components

- `kansoku-api`: shared wire types, event contracts, and route types;
- `kansoku-core`: authentication, ingestion, writer, storage, metrics, and telemetry;
- `kansoku-server`: the HTTP server and PostgreSQL migration executable;
- `kansoku-client`: the buffered Haskell producer and typed metrics client.

The server process contains the collector, writer, and query surface. PostgreSQL and ClickHouse
remain external durable services. A browser SDK, React SDK, and dashboard UI have not shipped;
browser and non-Haskell producers currently use HTTP directly.

## Later Scope

Possible future additions:

* browser and React SDKs
* dashboard UI and deployment/container examples
* implemented acquisition, organization, and custom metric routes
* statistical significance and sample-adequacy policy for experiments
* anomaly detection
* automated analytics summaries
* natural-language metric queries
* lifetime-first-seen and richer retention cohorts
* path analysis
* session replay metadata
* OpenTelemetry event bridge (trace export already exists)
* integration-event bridge
* data quality checks
* privacy controls
* tenant-level retention policies

## Design Philosophy

Kansoku should be:

* first-party
* event-first
* ClickHouse-native
* simple to self-host
* friendly to microservices
* friendly to automated agents
* opinionated enough to be useful
* generic enough to open source

Kansoku observes the system without becoming part of the business domain. It provides a unified observation layer for user behavior, application behavior, and business events while remaining independent of any specific product or workflow.
