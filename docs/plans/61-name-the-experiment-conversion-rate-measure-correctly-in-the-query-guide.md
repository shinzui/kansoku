---
id: 61
slug: name-the-experiment-conversion-rate-measure-correctly-in-the-query-guide
title: "Name the experiment conversion rate measure correctly in the query guide"
kind: exec-plan
created_at: 2026-11-06T04:21:08Z
intention: "intention_01m6qhd48bewqrhm4vj12ges5n"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-06T04:21:08Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-06T04:36:59Z
      mode: "update"
      note: "Record acceptance of IR-3 and its link to this plan."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T12:29:06Z
      mode: "implement"
      note: "Implement the guide measure correction and record acceptance evidence."
---

# Name the experiment conversion rate measure correctly in the query guide

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Follow `agents/skills/exec-plan/FRICTION.md` for implementation friction and distill durable decisions into `docs/adr/` at completion.

## Purpose / Big Picture


A reader building an experiment conversion chart must be able to find the measure the server actually returns. Correct the query guide to list `exposed`, `converted`, and `conversion_rate`, so consumers do not look for a nonexistent `rate` point. The observable result is agreement between the guide, the query compiler, and the existing response-decoding assertions. Server behavior remains unchanged.

## Progress


- [x] 2026-11-06: The experiment conversion guide names `exposed`, `converted`, and `conversion_rate`, with refreshed DOC-10 metadata and an additive update-log entry. Source inspection confirms both SQL paths and the decoded `group.measure` assertion agree; `just guides-check` passes for all 14 concepts and `git diff --check` passes.

## Surprises & Discoveries


## Decision Log


2026-11-06: Limit implementation to the guide correction and its required documentation metadata. The originating request explicitly preserves the existing API name; no compiler change, new alias, or new test suite is warranted for this prose correction.

## Outcomes & Retrospective


2026-11-06: AC-1 is satisfied. `docs/guides/query-metrics.md` now names the existing `conversion_rate` measure while retaining post-exposure ordering, multiple-variant counting, statistical-significance wording, and curl examples. The final guide diff contains only the measure correction and revision timestamp; the log adds one DOC-10 entry and preserves all historical content, including the provenance table. Server behavior and tests are unchanged.

`just guides-check` exited zero with `OK: 14 concepts (okf_version 0.2)`, and `git diff --check` exited zero. No implementation work remains. The friction query found no logged entries for this plan, and no new friction was encountered. Reviewing the Decision Log and implementation findings confirmed that ADR-6 already supplies the relevant architectural context; this prose correction introduces no durable decision requiring an ADR change.

## Context and Orientation


The source request is [docs/improvement-requests/name-the-experiment-conversion-rate-measure-in-the-query-guide.md](../improvement-requests/name-the-experiment-conversion-rate-measure-in-the-query-guide.md), identified as IR-3. Its AC-1 acceptance criterion requires the three names `exposed`, `converted`, and `conversion_rate`. A measure is the label in a returned point's `group.measure` that identifies what its numeric `value` represents. The first two measures count exposed and converted users; the third is their ratio, with zero for an empty denominator.

In `docs/guides/query-metrics.md`, the `Experiments` section describes `GET /metrics/experiments/conversion` and, before implementation, listed `rate`. In `kansoku-core/src/Kansoku/Metrics/Query.hs`, `compileTraitExperimentConversion` already emits `('conversion_rate',if(exposed=0,0.,converted/exposed))`; `buildExperimentConversionSQL` also emits this label. In `kansoku-core/test/Kansoku/QuerySpec.hs`, the test titled “builds exact conversion SQL with an explicit post-exposure ordering predicate” checks that SQL label, and the `experimentConversionPoint` assertion checks a decoded group containing `("measure", "conversion_rate")`.

The relevant architecture record is [docs/adr/0006-exposure-based-experiment-analytics.md](../adr/0006-exposure-based-experiment-analytics.md), found by scanning local ADR filenames and headings. It establishes exact conversion counts under current identity resolution, conversion only at or after exposure, counting a user in every observed variant, and no statistical-significance calculation. Preserve that context in the surrounding guide prose. This correction introduces no new architectural decision and needs no ADR edit.

The guide belongs to the documentation bundle governed by `docs/guides/profile.dhall`; its stable document identifier is `DOC-10`. Preserve its type, title, description, tags, and identifier. Update `generated.at` to the actual UTC revision time, using the established `generated.by: process:codex` actor when implemented by Codex. `docs/guides/log.md` records meaningful guide revisions. The `guides-check` recipe in `justfile` enforces document metadata and log freshness.

Existing [docs/friction-log/1-okf-log-append-removes-existing-guide-provenance-prose.md](../friction-log/1-okf-log-append-removes-existing-guide-provenance-prose.md), FRIC-1, records that automated log append can drop historical prose and its provenance table. Preserve all existing log content when inserting this update. At plan creation, the working tree already contains staged changes from other work, including `docs/guides/log.md`; inspect current differences and preserve them.

## Plan of Work


One milestone delivers the corrected reader contract. In the experiment conversion paragraph of `docs/guides/query-metrics.md`, replace only the measure name `rate` with `conversion_rate`, producing “The endpoint returns `exposed`, `converted`, and `conversion_rate` as separate points in each variant's `group`; it does not calculate statistical significance.” Preserve nearby semantics and curl examples. Refresh the guide's revision metadata and add a concise `Update` entry for DOC-10 under the matching UTC date in `docs/guides/log.md`, retaining existing entries and the historical provenance table.

Verify the sentence against both SQL construction paths and the decoding assertion, then run the guide validation and whitespace checks below. Record their results and mark the milestone complete only after AC-1 and the metadata checks pass. Review the plan's decisions for durable architectural changes; none are expected. IR-3 is accepted and linked to this plan; implementation now satisfies its acceptance criterion, as recorded in Outcomes & Retrospective.

## Concrete Steps


Run all commands from the repository root, the directory containing `justfile` and `kansoku-core/`. Inspect existing edits before touching the guide or log:

```bash
git status --short
git diff -- docs/guides/query-metrics.md docs/guides/log.md
git diff --cached -- docs/guides/query-metrics.md docs/guides/log.md
sed -n '375,400p' docs/guides/query-metrics.md
rg -n 'compileTraitExperimentConversion|conversion_rate' kansoku-core/src/Kansoku/Metrics/Query.hs kansoku-core/test/Kansoku/QuerySpec.hs
```

The guide currently says `rate`, while source and assertions say `conversion_rate`. Make the scoped edits described above. Obtain the revision timestamp with:

```bash
date -u +%Y-%m-%dT%H:%M:%SZ
```

Insert the DOC-10 log entry under that date without rewriting the log's historical content. Then verify:

```bash
just guides-check
git diff --check
rg -n 'The endpoint returns' docs/guides/query-metrics.md
git diff -- docs/guides/query-metrics.md docs/guides/log.md
```

Expect `just guides-check` to exit zero with no profile or log-enforcement errors, `git diff --check` to exit zero with no whitespace errors, and the matched guide sentence to include `conversion_rate`. The final diff should show only the intended sentence, revision metadata, and additive log entry for this work. Compare staged differences separately when needed to distinguish pre-existing edits.

When recording an implementation commit, use a Conventional Commit message such as `docs: correct experiment conversion measure name` and include both trailers:

```text
ExecPlan: docs/plans/61-name-the-experiment-conversion-rate-measure-correctly-in-the-query-guide.md
Intention: intention_01m6qhd48bewqrhm4vj12ges5n
```

## Validation and Acceptance


AC-1 is satisfied when a reader at the conversion endpoint example sees exactly the three measure names `exposed`, `converted`, and `conversion_rate`, and can match `conversion_rate` to the SQL tuples and decoded `group.measure` assertion described above. The paragraph must retain its post-exposure, multiple-variant, and statistical-significance statements. This is a documentation correction; source inspection supplies the existing behavior evidence, and no server startup, database fixture, new automated test, or full Haskell rebuild is needed.

Required acceptance also includes passing `just guides-check`, passing `git diff --check`, and confirming that the log's historical prose and unrelated work survive. If validation exposes a pre-existing unrelated problem, record the exact failure and distinguish it from this correction instead of silently widening scope or claiming a pass.

## Idempotence and Recovery


The correction and read-only checks can be repeated safely. If the guide already names `conversion_rate`, verify it and avoid duplicate log entries or unnecessary timestamp changes. Reuse this plan rather than running the initializer again. If an edit damages the log, restore only this task's changes using the pre-edit working content; do not restore the whole file from HEAD, because it may contain another task's staged work. No migration or data recovery is involved.

## Interfaces and Dependencies


The existing public interface is `GET /metrics/experiments/conversion` with measure labels in `group.measure`. Preserve its names, numeric values, and response shape. The only implementation targets are `docs/guides/query-metrics.md`, `docs/guides/log.md`, and this plan's progress/evidence. Existing `just` and `okf` tooling supplies the documentation validation through `just guides-check`. No dependency version, package API, parent MasterPlan, or prerequisite feature change is required.

Revision note (2026-11-06): At the user’s request, recorded IR-3 as accepted and linked it to this plan; implementation scope and acceptance remain unchanged.
