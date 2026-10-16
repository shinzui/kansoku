---
type: Term
title: "observed session duration"
description: "The elapsed time from the first to the last retained observed event in a web session."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-56
status: current
tags: [web]
related:
  - TERM-53
  - TERM-55
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
---

# observed session duration

The elapsed time from the first to the last retained observed event in a web session.

The session average includes one-event sessions with zero duration and page_leave observations. It measures elapsed observation, not active reading time. Missing exit events can understate it; late facts can extend it, and retention can shorten it. A page_leave payload’s duration is not the session measure itself.

Related: [web session](web-session.md), [bounce rate](bounce-rate.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
