# TAN production release-owner decision

Approval recorded at 2026-11-08T05:24:18Z UTC for source
`7c1132d74c8cb4fd5702b3ba8394aa1f52f66780` and target `tan-production`.

The requesting user explicitly approved publication after being shown all four
limitations. The approving identity is the requesting release owner in Codex thread
`01a1b97f-df14-7d21-9474-98412788611a`; no separate personal name was supplied.
This records the participant's decision, not an authenticated signature or an
identity inferred from Git configuration.

The immediately preceding assistant message stated:

> The image is built and tested. Before publishing it, the plan requires your approval of four known limitations:
>
> - Old Mac startup crashes remain unexplained.
> - Some vendor security fixes have unpublished source.
> - Full replicated tests haven’t run inside this exact image.
> - The managed endpoint isn’t certified.

The user's response was:

> i approve

This response explicitly approves the four presented limitations and the release
requested in the same exchange. It follows the detailed proposed reasons in the
[target dossier](tan-production-target.md); those reasons are retained below and in
[tan-production-release.json](tan-production-release.json). These are accepted
residual risks, not evidence that the crashes are fixed, full image database tests
passed, or the provider endpoint is certified.

The decision binds preserved Docker archive SHA-256
`db8197a8161e5cf52fdd1c7a57939d19590bcbd3c7886a84f311e898264f8e86` and Apple Container local OCI index
`sha256:783b91e441775a30189cd6d4988cfa4b5dce5fc16756546331981a112b846790`. The latter is not a registry digest.
Publication connected this preserved candidate to the verified immutable
registry reference without rebuilding its content.

## startup-crash

Accept the unresolved developer-fixture startup risk for this managed Altinity deployment, retaining failures and requiring any future startup failure to fail its acceptance run.

## security-patch-review

Select the vendor's exact security-fixed patch with its disclosed source limitation, retain exact-version admission, and require TAN to verify deployed version and follow vendor security updates.

## linux-amd64-image

Accept this precisely bounded packaged-image/platform coverage gap using unchanged passing prerequisite behavior, while retaining TAN's managed migration and event-flow rehearsal obligation.

## managed-endpoint

Accept the uncertified endpoint with independently verified full replica inventory, storage/fsync and grants, normal TLS verification, external drain and explicit uncertain-outcome recovery required during TAN onboarding.

TAN retains responsibility for production inventory, storage/fsync, grants, external drain and managed migration/event-flow rehearsal. This approval authorizes artifact publication; it does not perform or certify a production migration.

## Verified publication binding

`gcr.io/tan-ng/kansoku@sha256:a78b668dbc98567bfd2d031f9b3aaf3a22b1f3f4bd4fbfd3ca3605dfbf98d213` passed readback verification against the approved candidate. All three exact plan byte streams, filesystem layers and source labels match. See [publication evidence](tan-production-publication.json) and [the final artifact](tan-production-qualified-artifact.json).
