---
type: Improvement Request
title: Accept TAN production as a deployment target
description: Resolve or explicitly accept the production gates recorded in the clickhouse-migrate adoption evidence (startup crash disposition, security and patch review, unselected deployment target, Linux amd64 application image, uncertified managed endpoint) for Altinity 26.3.60.10002.altinitystable on tan-production, and release an image whose identity and evidence TAN's production stack can pin.
generated:
  by: process:claude-code
  at: "2026-11-08T00:00:15Z"
requestId: IR-12
status: completed
completedAt: "2026-11-08T05:28:00Z"
resolution: >-
  AC-1 through AC-5 completed by plan 64. The exact TAN target and four dated
  owner-accepted residual risks are retained in docs/evidence/tan-production-target.md
  and tan-production-release-decision.md. The Linux amd64 image is published and
  digest-readback verified; docs/evidence/tan-production-qualified-artifact.json
  records source 7c1132d74c8cb4fd5702b3ba8394aa1f52f66780, toolkit revision and exact
  replicated-native/PostgreSQL stdout hashes. Managed certification and full Linux
  image behavioral coverage are accepted gaps; production onboarding remains TAN-owned.
targetPlan: docs/plans/64-accept-tan-production-as-a-deployment-target.md
origin: mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster
dependencies:
  - ref: mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-10
    kind: hard
    reason: The production target is a replicated cluster, so it can only be qualified with the replicated migration path.
  - ref: mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-11
    kind: hard
    reason: Production acceptance includes correct writes and maintenance jobs across both replicas.
acceptanceCriteria:
  - id: AC-1
    statement: docs/evidence/clickhouse-migrate-adoption.md names the selected production target (Altinity.Cloud tan-production, one shard, two replicas, 26.3.60.10002.altinitystable, one HTTPS endpoint on port 8443) and replaces "the actual deployment OS/architecture, endpoint, storage and version have not been selected".
    verification: Read the evidence file's platform and production disposition section.
  - id: AC-2
    statement: The startup SIGSEGV recorded in db/clickhouse/qualification/matrix.json and the intervening security and patch review each have a recorded disposition for the selected target, either resolved or explicitly accepted by the Kansoku release owner with a date and reason.
    verification: Read the matrix and evidence entries; an unresolved gate without a recorded acceptance fails this criterion.
  - id: AC-3
    statement: The Linux amd64 application image that runs on TAN's GKE nodes is either covered by the replicated acceptance from IR-10 and IR-11, or its gap is explicitly accepted by the release owner.
    verification: The evidence names the image digest, its architecture and which acceptance runs covered that exact artifact.
  - id: AC-4
    statement: The release owner records acceptance of the uncertified single load-balanced managed endpoint, relying on clickhouse-migrate's per-connection replica UUID admission to fail closed.
    verification: Read the evidence entry, which names the risk, the fail-closed behaviour and the date.
  - id: AC-5
    statement: A released image gcr.io/tan-ng/kansoku@sha256 digest is published with its source revision, clickhouse-migrate revision and native and PostgreSQL plan hashes, in the shape of tan-app-infrastructure's pulumi/apps/kansoku/qualified-artifact.json.
    verification: The evidence file lists the digest and hashes and ties the digest to the source revision it was built from (for example through the Nix package identity), so TAN can pin the digest and cite that evidence.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-08T00:00:15Z"
    document_timestamp: "2026-11-08T00:00:15Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Kansoku 2008b67's docs/evidence/clickhouse-migrate-adoption.md and
      docs/guides/clickhouse-migrations.md, tan-infrastructure altinity/clusters/production.json
      and clickhouse-migrate 0e75c4c's compatibility matrix. The gates are quoted from Kansoku's
      own evidence; this request does not judge them. No independent verification attestation
      is claimed.
---

# Accept TAN production as a deployment target

**Authored by:** a `claude-code` session in `mori://tan/tan-app-infrastructure`, planning
Kansoku's production onboarding
(`mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster`).
**Addressed to:** `shinzui/kansoku` agents and the Kansoku release owner.
**Created:** 2026-11-08.

**Implementation plan:** [ExecPlan 64: Accept TAN production as a deployment target](../plans/64-accept-tan-production-as-a-deployment-target.md).
Completed by Plan 64 on 2026-11-08. [Release evidence](../evidence/tan-production-release.json), [the explicit owner decision](../evidence/tan-production-release-decision.md), and [the published artifact](../evidence/tan-production-qualified-artifact.json) establish AC-1 through AC-5. The release retains all accepted coverage and endpoint limits.

This is the third of three requests filed together, after IR-10 and IR-11.


## Why

Kansoku's own evidence says it is not ready for any production target.
`docs/evidence/clickhouse-migrate-adoption.md` records that:

- "the actual deployment OS/architecture, endpoint, storage and version have not been
  selected";
- the Linux amd64 application image is not covered by the arm64 qualification;
- "crash disposition and intervening patch/security review remain production gates".

TAN now has a concrete target. tan-infrastructure's `altinity/clusters/production.json`
describes `tan-production`: one shard, two replicas in `us-west1-b` and `us-west1-c`,
`26.3.60.10002.altinitystable`, Keeper run by Altinity, secure transport, and daily backups at
05:00 UTC with seven kept. clickhouse-migrate 0.1.1.0 qualifies that exact version for one shard
and two replicas, on Linux arm64 fixtures only. TAN reaches the cluster through one
load-balanced HTTPS endpoint, which clickhouse-migrate exercises but does not certify for
managed clouds.

TAN's production stack pins one immutable image digest and its evidence. Its onboarding plan
will not begin until these gates are closed or accepted in writing.


## Requested change

- **Record the selected target.** Put `tan-production`'s version, topology and endpoint in the
  adoption evidence and the qualification matrix.
- **Close or accept each open gate:**
  - the startup SIGSEGV
  - the security and patch review between the qualified candidate and the selected version
  - the Linux amd64 application image
  - the uncertified managed endpoint

  "Accept" means the release owner records a dated reason. It does not mean leaving the gate
  silently open.
- **Publish the release.** Publish the image that carries IR-10 and IR-11, and give its digest,
  source revision, clickhouse-migrate revision and plan hashes. TAN's plan copies them into a
  production artifact file next to staging's `qualified-artifact.json`.


## Notes

Staging (`tan-staging`, one replica, `Atomic` databases, direct target) keeps running the
existing history and is not part of this request. TAN will move staging to the new image first
with an ordinary image deploy that applies zero migrations. That proves the direct path
unchanged on real data, but proves nothing about the replicated path.
