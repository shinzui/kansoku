# Bundle Update Log

## 2026-10-16

* **Adoption**: Bootstrap OKF 0.2 with the frozen v0.20.0 [capabilities profile](mori://shinzui/okf-profiles/profiles/capabilities).
* **Population**: Add CAP-1 through CAP-19 from current source, tests and adopter guides, covering credentials, ingestion, schemas, delivery, identity, metrics, web sessions, activity, funnels, paths, experiments, traits, cohorts, custom metrics, organisations, maintenance, telemetry, Haskell clients and SQL readers. Verify evidence paths; retain experimental/unreleased compatibility and explicit limits. No independent review or full runtime acceptance is attested.
* **Integration**: Declare the bundle in `mori.dhall`, link it from repository navigation and include its dedicated validation recipe in `just check`.
* **Validation**: Check the frozen descriptor and manifest types, OKF profile/log enforcement, Mori catalog validation, evidence/anchor paths, local references, topic-index coverage and graph relationships. Independent capability reviews remain pending; strict capability validation reports that recommended provenance.
