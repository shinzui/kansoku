# Bundle Update Log

## 2026-10-20
* **Update**: Withdraw IR-1 at the requesting operator's direction: startup queue provisioning stays, and the runtime's permission to create its queue moves to the platform as `mori://shinzui/nagare/okf/improvement-requests/concepts/IR-35`. IR-2 is unaffected.

## 2026-10-19
* **Add**: Propose IR-1 and IR-2 from `mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`, after a full privilege audit of 9127c47 against Nagare v0.7.0 app databases. IR-1 moves PGMQ queue creation into migrations so the server runs with a DML-only PostgreSQL role. IR-2 makes the ClickHouse maintenance ceremony, admin drain check and restore verification work on a shared server, depending on `mori://shinzui/nagare/okf/improvement-requests/concepts/IR-30` and `mori://shinzui/nagare/okf/improvement-requests/concepts/IR-31`.
* **Adoption**: Adopt the `cross-repository-improvement-requests` profile (`coordination.improvementRequests`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.20.0/package.dhall.
