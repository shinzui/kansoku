# 観測（Kansoku） — Product and Web Analytics Service

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
Kansoku ingestion API
        |
        v
Durable queue / Pub/Sub
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

```ts
type AnalyticsEvent = {
  eventId: string
  eventName: string
  source: "web" | "app" | "service" | "worker" | "email" | "agent"
  sourceService?: string

  occurredAt: string
  receivedAt: string

  anonymousId?: string
  userId?: string
  organizationId?: string
  accountId?: string
  sessionId?: string

  url?: string
  referrer?: string
  utmSource?: string
  utmMedium?: string
  utmCampaign?: string
  utmContent?: string
  utmTerm?: string

  correlationId?: string
  causationId?: string
  sourceEventId?: string
  sourceGlobalPosition?: number

  properties: Record<string, unknown>
  context: Record<string, unknown>
}
```

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

Kansoku stores all events in an append-only raw events table.

```sql
analytics.events_raw
```

Suggested ordering:

```sql
ORDER BY (account_id, user_id, event_name, occurred_at)
PARTITION BY toYYYYMM(occurred_at)
```

The raw table is the source of truth.

## Derived Tables and Rollups

Use ClickHouse materialized views for common metrics.

Examples:

* daily event counts
* daily active users
* weekly active users
* page views by route
* campaign conversions
* feature adoption
* account activation
* organization activity
* funnel step counts
* retention cohorts

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

The service should avoid mutating raw historical events unless absolutely necessary. Identity can be resolved in query-time views or derived tables.

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

Initial endpoints:

```txt
GET /metrics/events
GET /metrics/page-views
GET /metrics/sessions
GET /metrics/funnel
GET /metrics/retention
GET /metrics/acquisition
GET /metrics/feature-adoption
GET /metrics/conversion
GET /metrics/users
GET /metrics/organizations
GET /metrics/custom
```

The goal is to expose useful product and business metrics without becoming a generic BI tool.

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

## Initial Components

```txt
kansoku-server
kansoku-collector
kansoku-writer
kansoku-clickhouse
kansoku-js
kansoku-haskell
kansoku-react
```

## MVP Scope

The first version should include:

1. HTTP event ingestion
2. batch ingestion
3. browser SDK
4. backend/server SDK
5. raw ClickHouse event table
6. identity events
7. page views
8. sessions
9. UTM attribution
10. product events
11. materialized views for daily metrics
12. semantic metrics layer
13. typed query API
14. simple dashboard integration

## Later Scope

Possible future additions:

* experimentation support
* feature flag exposure tracking
* anomaly detection
* automated analytics summaries
* natural-language metric queries
* retention cohorts
* path analysis
* session replay metadata
* OpenTelemetry bridge
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

