# Bundle Update Log

## 2026-11-14

* **Update**: TERM-70: distinguish persistent admission fencing from owner-bound external native drain and shared-server availability.


## 2026-11-13

* **Update**: TERM-77 and TERM-78 distinguish durable admission readiness from pipeline health.


* **Update**: TERM-47 and TERM-49: define calendar cohort labels, period offsets and independent starts/returns.

## 2026-11-08

* **Update**: TERM-56: Preserve diagnostic timestamps in observed session duration
* **Update**: TERM-55: Exclude both diagnostic names from engagement for every version
* **Update**: TERM-53: Clarify diagnostic membership and duration without engagement

## 2026-11-01

* **Update**: Align liveness and readiness terminology with the two canonical probe endpoints.

## 2026-10-16

* **Adoption**: Bootstrap OKF 0.2 with the frozen v0.20.0 [terminology profile](mori://shinzui/okf-profiles/profiles/terminology).
* **Population**: Add TERM-1 through TERM-79 with topic groups, definitions, distinctions, local related/broader links and checked repository anchors. Audit events/contracts, credentials, acceptance/delivery/recovery, identity/traits/organisations, query bounds, activity/retention, cohorts/custom metrics, web attribution, funnels/paths, experiments and lifecycle operations. Generic Haskell/framework internals, individual environment-variable names and every command/endpoint spelling stay in their authoritative guides rather than becoming terms. Future UI, SDK or statistical features are omitted because they are not supplied here. No independent review is attested.
* **Integration**: Declare the bundle in `mori.dhall`, link it from repository navigation and include its dedicated validation recipe in `just check`.
* **Validation**: Check the frozen descriptor and manifest types, OKF profile/log enforcement, Mori catalog validation, evidence/anchor paths, local references, topic-index coverage and graph relationships. Independent capability reviews remain pending; strict capability validation reports that recommended provenance.
