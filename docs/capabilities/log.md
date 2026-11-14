# Bundle Update Log

## 2026-11-14

* **Update**: CAP-16 and CAP-20: record portable owner-bound maintenance, complete recovery sets and the actual shared-server/local Nagare evidence.


## 2026-11-13

* **Update**: CAP-17 separates admission readiness and pipeline health; durable delivery validates topology before every batch.


* **Update**: CAP-8: describe exact calendar retention and verified public/native weekly and monthly behavior.

## 2026-11-11

* **Population**: Add CAP-20 (explicit direct and replicated ClickHouse migrations via `kansoku-ch-migrate`) and CAP-21 (source-built Linux container image) from current source, tests and guides.
* **Update**: CAP-2 rejects storage-incompatible flattened JSON paths before acceptance; CAP-3 publishes catalog v5 `maxLength` and declares `client_error` v1 and `web_vital` v1.
* **Update**: CAP-4 adds verified native TLS and the replicated quorum writer policy; CAP-16 adds replica-bound maintenance jobs; CAP-19 documents eventually consistent reads and synchronized read-back.
* **Update**: CAP-6, CAP-8 and CAP-14 accept `session:` attributes on page views, users and custom metrics; CAP-7 adds `containsEvent` session selection, first-touch acquisition conversions and the `ai_assistant` channel.
* **Update**: CAP-13 cohort conditions accept condition-local `org:` traits and require CAP-15; CAP-17 records removal of legacy `/health` and `/ready`; CAP-18 points browser producers at the published `mori://shinzui/kansoku-ts` packages.

## 2026-11-08

* **Update**: CAP-7: Describe diagnostic classification and retained session correction

## 2026-11-06

* **Update**: CAP-14 includes exact custom percentiles, saved quantiles and numeric sample eligibility.

* **Update**: Document explicit whole-range metric capabilities.

## 2026-10-16

* **Adoption**: Bootstrap OKF 0.2 with the frozen v0.20.0 [capabilities profile](mori://shinzui/okf-profiles/profiles/capabilities).
* **Population**: Add CAP-1 through CAP-19 from current source, tests and adopter guides, covering credentials, ingestion, schemas, delivery, identity, metrics, web sessions, activity, funnels, paths, experiments, traits, cohorts, custom metrics, organisations, maintenance, telemetry, Haskell clients and SQL readers. Verify evidence paths; retain experimental/unreleased compatibility and explicit limits. No independent review or full runtime acceptance is attested.
* **Integration**: Declare the bundle in `mori.dhall`, link it from repository navigation and include its dedicated validation recipe in `just check`.
* **Validation**: Check the frozen descriptor and manifest types, OKF profile/log enforcement, Mori catalog validation, evidence/anchor paths, local references, topic-index coverage and graph relationships. Independent capability reviews remain pending; strict capability validation reports that recommended provenance.
