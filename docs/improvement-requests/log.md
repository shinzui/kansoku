# Bundle Update Log

## 2026-11-14

* **Update**: IR-2: complete MasterPlan 7 with dedicated/generic/actual local Nagare evidence, exact source candidates and platform-specific integration dependencies.

## 2026-11-13

* **Update**: IR-3 status accepted -> completed (completedAt 2026-11-06T12:29:54Z): Plan 61 corrected the experiment conversion measure name in the query guide (commit 1fb1eac).


* **Update**: IR-4 status accepted -> completed (completedAt 2026-11-06T05:40:12Z): Plan 60 delivered AC-1 to AC-4 as explicit whole-range aggregation (commits a665ec1, 81b4df6).


* **Update**: IR-5 status accepted -> completed (completedAt 2026-11-06T13:42:17Z): Plan 56 delivered AC-1 to AC-4 with acquisition and full packaged acceptance (commits 40da5c9, 2d1202a).


* **Update**: IR-6 status accepted -> completed (completedAt 2026-11-06T04:50:51Z): Plan 58 delivered AC-1 to AC-3 as channel rule version 2 (commit 406c882).


* **Update**: IR-7 status proposed -> completed (completedAt 2026-11-06T12:49:52Z) and targetPlan linked to docs/plans/55-add-percentile-aggregation-to-custom-metrics.md: Plan 55 delivered AC-1 to AC-4 (commits 6324cad, eb0fb53). No acceptance had been logged.


* **Update**: IR-10 status accepted -> completed (completedAt 2026-11-08T02:31:43Z): Plan 62 delivered AC-1 to AC-5; just ch-migrations-replicated passed on the two-replica Altinity candidate (commits df07621, f5a37ca).


* **Update**: IR-11 status accepted -> completed (completedAt 2026-11-08T04:49:33Z): Plan 63 delivered AC-1 to AC-4 with source and packaged replicated runtime evidence in docs/evidence/replicated-runtime.md (commits 2ee9a49, a40b20a).


* **Update**: IR-17 status accepted -> completed (completedAt 2026-11-13T01:51:44Z): Plan 67 delivered AC-1 to AC-5 with full packaged acceptance (commits 0432449, be4d38b).


* **Update**: Correct IR-18 body prose that still said implementation had not started; frontmatter already recorded completion by Plan 68.


* **Update**: Link IR-2 targetPlan to docs/masterplans/7-operate-kansoku-clickhouse-safely-across-deployment-platforms.md, which delivers it through ExecPlans 50-53. Status stays proposed: none of those plans has started.


* **Update**: Audit (2026-11-13) of all 20 requests against plans, source and commits. Statuses not listed below were already accurate; IR-15 and IR-16 remain proposed with no plan or implementation.


* **Update**: Complete IR-20: Plan 70 delivers calendar-period retention with separate start/return activity; native, HTTP/client, contract and full packaged acceptance pass.

* **Update**: Link IR-20 to ExecPlan 70 for calendar-period retention with separate start and return events; implementation has not started.


* **Update**: Complete IR-19: plan 69 delivers saved analyses with revision safety, quotas, filtered pages, typed clients and documented contracts; full packaged acceptance passes.


* **Add**: Propose IR-20 from `mori://shinzui/kansoku-ui/plans/36-analyse-retention-by-daily-weekly-or-monthly-cohorts-with-start-and-return-events`: weekly and monthly retention cohorts with offsets in that unit, and a start event and return event each with its own filters beside the shared filters, for kansoku-ui's cohort analysis.

* **Update**: Complete IR-18: plan 68 delivers identified-user metric selection; focused eight-route HTTP, native, compiler/client and documentation checks pass.


* **Update**: Accept IR-18 for implementation and link targetPlan to docs/plans/68-select-identified-users-in-metric-queries.md; implementation has not started.


* **Update**: Accept IR-17 for implementation and link targetPlan to docs/plans/67-read-identified-users-profiles-and-event-history.md; implementation has not started.

## 2026-11-12

* **Add**: Propose IR-19 from `mori://shinzui/kansoku-ui/masterplans/7-build-the-insights-library-of-saved-analyses`: an account-scoped saved-analysis resource (name, description, kind of trends, funnel or retention, and an opaque client-versioned JSON document) with CRUD, pages ordered by most recent update, a kind filter and optimistic concurrency, for kansoku-ui's Insights library.

* **Add**: Propose IR-17 and IR-18 from `mori://shinzui/kansoku-ui/masterplans/6-build-the-users-directory-and-user-profile-pages`, modelled on the People screen of an open-source web-analytics product. IR-17 adds a read-only users resource: a directory of identified users with current traits and first and last activity, one user's profile and identity evidence counts, one user's resolved event history with declared properties only, and exact identified and anonymous counts for a range. IR-18 adds a filter dimension selecting one identified user on metric routes (soft dependency on IR-17).

## 2026-11-09
* **Create**: File IR-16 for an authenticated live activity WebSocket with snapshot, updates, recovery and bounded consumers.
* **Add**: Propose IR-15 from `mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster`: keep the server starting and accepting events while ClickHouse is unavailable.

## 2026-11-08
* **Update**: IR-14: complete bounded whole-session containsEvent selection with native, typed-client and three-mode packaged public acceptance evidence.
* **Update**: IR-13: Complete diagnostic non-engagement classification, fenced retained-session correction and public/native upgrade acceptance in plan 65
* **Update**: Complete AC-1 through AC-5 with dated explicit owner risk acceptance and published Linux amd64 image/source/plan hashes verified from registry readback.
* **Update**: Accept IR-12 for implementation and link targetPlan to docs/plans/64-accept-tan-production-as-a-deployment-target.md; implementation and release-owner risk acceptance have not occurred.
* **Update**: Accept IR-11 for implementation and link targetPlan to docs/plans/63-keep-writes-and-maintenance-jobs-correct-on-a-replicated-cluster.md; implementation has not started.
* **Add**: Propose IR-13 and IR-14 from `mori://shinzui/kansoku-ui/masterplans/4-build-the-health-tab-of-the-reports-page` for its Health tab. IR-13 stops counting client\_error and web\_vital as session engagement, so kansoku-js's opt-in capture leaves bounce rate unchanged (soft dependency on IR-8). IR-14 lets `/metrics/sessions` select sessions that contain an event, for the share of sessions with an error (soft dependency on IR-8).
* **Update**: Accept IR-10 for implementation and link targetPlan to docs/plans/62-run-clickhouse-migrations-on-a-replicated-cluster.md; implementation has not started.
* **Add**: Propose IR-10 to IR-12 from `mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster` for production on the two-replica `tan-production` Altinity cluster. IR-10 runs ClickHouse migrations on a replicated target with a separate replicated baseline and fresh v2 ledger, leaving the direct target and its history unchanged. IR-11 makes writer durability, read-back checks and the erase/retention quiesce and mutation checks hold across every replica (hard dependency on IR-10). IR-12 records the production target and closes or accepts the adoption evidence production gates (hard dependencies on IR-10 and IR-11).

## 2026-11-06
* **Update**: Complete IR-9 AC-1 through AC-4: session-scoped event filtering/grouping, retained attribution parity, saved ratios and query documentation; native, custom, deterministic and full packaged acceptance passed.
* **Update**: Complete IR-8: enforced client\_error/web\_vital v1, public error/user/p75 query evidence, sending recipes and actual opt-in SDK plan; all required gates passed.
* **Update**: Accept IR-3 for implementation and link targetPlan to docs/plans/61-name-the-experiment-conversion-rate-measure-correctly-in-the-query-guide.md; implementation has not started.
* **Update**: Accept IR-9 for implementation and link targetPlan to docs/plans/59-filter-and-group-events-by-their-session-attributes.md; implementation has not started.
* **Update**: Accept IR-4 for implementation and link targetPlan to docs/plans/60-count-unique-users-over-a-whole-query-range.md; implementation has not started.
* **Update**: Accept IR-8 for implementation and link targetPlan to docs/plans/57-declare-client-error-and-web-vital-events.md; implementation has not started.
* **Update**: Accept IR-6 for implementation and link targetPlan to docs/plans/58-classify-ai-assistant-referrals-as-a-channel.md; implementation has not started.
* **Update**: Accept IR-5 for implementation and link targetPlan to docs/plans/56-attribute-conversions-to-first-touch-acquisition.md; implementation has not started.
* **Add**: Propose IR-9 from `mori://shinzui/kansoku-ui/masterplans/3-build-the-reports-page`: session-scoped dimensions on page-views, users and custom metrics, so events can be filtered and grouped by the first-touch attributes of the session they belong to.

## 2026-11-05
* **Add**: Propose IR-4 to IR-8 from `mori://shinzui/kansoku-ui` while planning its Reports page, modelled on the reports of an open-source web-analytics product. IR-4 counts unique users over a whole range. IR-5 attributes conversions to first-touch acquisition (soft dependency on IR-4). IR-6 adds an ai\_assistant channel in a new channel rule version. IR-7 adds a percentile aggregation to custom metrics. IR-8 declares client\_error and web\_vital events, with a browser SDK follow-up for `mori://shinzui/kansoku-ts` (hard dependency on IR-7).
* **Add**: Propose IR-3 from `mori://shinzui/kansoku-ui/plans/11-add-a-chart-kind-registry-composed-chart-inputs-and-a-chart-options-panel`: the query guide names the experiment conversion measure `rate` where the compiler and its tests emit `conversion_rate`.

## 2026-10-20
* **Update**: Withdraw IR-1 at the requesting operator's direction: startup queue provisioning stays, and the runtime's permission to create its queue moves to the platform as `mori://shinzui/nagare/okf/improvement-requests/concepts/IR-35`. IR-2 is unaffected.

## 2026-10-19
* **Add**: Propose IR-1 and IR-2 from `mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`, after a full privilege audit of 9127c47 against Nagare v0.7.0 app databases. IR-1 moves PGMQ queue creation into migrations so the server runs with a DML-only PostgreSQL role. IR-2 makes the ClickHouse maintenance ceremony, admin drain check and restore verification work on a shared server, depending on `mori://shinzui/nagare/okf/improvement-requests/concepts/IR-30` and `mori://shinzui/nagare/okf/improvement-requests/concepts/IR-31`.
* **Adoption**: Adopt the `cross-repository-improvement-requests` profile (`coordination.improvementRequests`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.20.0/package.dhall.
