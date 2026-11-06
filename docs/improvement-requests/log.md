# Bundle Update Log

## 2026-11-06
* **Update**: Accept IR-3 for implementation and link targetPlan to docs/plans/61-name-the-experiment-conversion-rate-measure-correctly-in-the-query-guide.md; implementation has not started.
* **Update**: Accept IR-9 for implementation and link targetPlan to docs/plans/59-filter-and-group-events-by-their-session-attributes.md; implementation has not started.
* **Update**: Accept IR-4 for implementation and link targetPlan to docs/plans/60-count-unique-users-over-a-whole-query-range.md; implementation has not started.
* **Update**: Accept IR-8 for implementation and link targetPlan to docs/plans/57-declare-client-error-and-web-vital-events.md; implementation has not started.
* **Update**: Accept IR-6 for implementation and link targetPlan to docs/plans/58-classify-ai-assistant-referrals-as-a-channel.md; implementation has not started.
* **Update**: Accept IR-5 for implementation and link targetPlan to docs/plans/56-attribute-conversions-to-first-touch-acquisition.md; implementation has not started.
* **Add**: Propose IR-9 from `mori://shinzui/kansoku-ui/masterplans/3-build-the-reports-page`: session-scoped dimensions on page-views, users and custom metrics, so events can be filtered and grouped by the first-touch attributes of the session they belong to.

## 2026-11-05
* **Add**: Propose IR-4 to IR-8 from `mori://shinzui/kansoku-ui` while planning its Reports page, modelled on the reports of an open-source web-analytics product. IR-4 counts unique users over a whole range. IR-5 attributes conversions to first-touch acquisition (soft dependency on IR-4). IR-6 adds an ai_assistant channel in a new channel rule version. IR-7 adds a percentile aggregation to custom metrics. IR-8 declares client_error and web_vital events, with a browser SDK follow-up for `mori://shinzui/kansoku-ts` (hard dependency on IR-7).
* **Add**: Propose IR-3 from `mori://shinzui/kansoku-ui/plans/11-add-a-chart-kind-registry-composed-chart-inputs-and-a-chart-options-panel`: the query guide names the experiment conversion measure `rate` where the compiler and its tests emit `conversion_rate`.

## 2026-10-20
* **Update**: Withdraw IR-1 at the requesting operator's direction: startup queue provisioning stays, and the runtime's permission to create its queue moves to the platform as `mori://shinzui/nagare/okf/improvement-requests/concepts/IR-35`. IR-2 is unaffected.

## 2026-10-19
* **Add**: Propose IR-1 and IR-2 from `mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`, after a full privilege audit of 9127c47 against Nagare v0.7.0 app databases. IR-1 moves PGMQ queue creation into migrations so the server runs with a DML-only PostgreSQL role. IR-2 makes the ClickHouse maintenance ceremony, admin drain check and restore verification work on a shared server, depending on `mori://shinzui/nagare/okf/improvement-requests/concepts/IR-30` and `mori://shinzui/nagare/okf/improvement-requests/concepts/IR-31`.
* **Adoption**: Adopt the `cross-repository-improvement-requests` profile (`coordination.improvementRequests`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.20.0/package.dhall.
