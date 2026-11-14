---
name: release
description: Release Kansoku's Haskell packages following PVP with independent per-package versions, tags, and GitHub releases. kansoku-api and kansoku-client are also uploaded to Hackage; kansoku-core and kansoku-server are tagged and released on GitHub only.
argument-hint: "[major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# Kansoku Release Skill

Release Kansoku's Haskell packages following the Haskell **PVP** (`A.B.C.D`).
Every package versions, tags, and releases **independently** — this is not a
single shared-version release.

There are two release tracks:

- **Hackage + GitHub** — the reusable libraries that third parties consume.
- **GitHub only (tag-only)** — the application packages: they get a version
  bump, changelog, git tag, and GitHub release, but are **never uploaded to
  Hackage**.

Run this skill inside `nix develop` (the project dev shell provides `cabal`,
`nix`, `gh`, and the formatter).

## Packages and tracks

**Hackage + GitHub**, published in this dependency order:

1. **kansoku-api** (`kansoku-api/`) — shared Servant route types, analytics
   event types, metric DTOs, validation, and the Kansoku prelude. No internal
   dependencies; every external dependency is on Hackage.
2. **kansoku-client** (`kansoku-client/`) — the buffered Haskell producer SDK.
   Depends on **kansoku-api** (its only internal dependency).

**GitHub only (tag + release, no Hackage upload)**:

- **kansoku-core** (`kansoku-core/`) — the application runtime. It
  `build-depends` on a **git-sourced** package that is not on Hackage
  (`hs-opentelemetry-instrumentation-servant` via `source-repository-package`),
  so it is not cleanly
  Hackage-installable. Tag and GitHub-release it for traceability, but do not
  `cabal upload` it.
- **kansoku-server** (`kansoku-server/`) — the `kansoku-server`,
  `kansoku-migrate`, `kansoku-admin`, and `kansoku-ch-migrate` executables.
  This is the application, not a library. Tag and GitHub-release it; its
  runnable distribution is the TAN container image (see
  `scripts/check_tan_release.py`), not a Hackage package.

**Not released at all**: `vendor/ClickHaskell` — a vendored third-party
dependency, not ours.

> If you believe a tag-only package should now ship to Hackage (e.g. its git
> deps reached Hackage), stop and confirm the scope change with the user before
> uploading — publishing to Hackage is irreversible.

## Versioning strategy

The Haskell PVP version format is `A.B.C.D`:

- `A.B` — **major**: breaking API changes (removed/renamed exports, changed
  types, changed semantics).
- `C` — **minor**: backwards-compatible API additions (new exports, new
  modules, new instances).
- `D` — **patch**: bug fixes, documentation, internal-only changes,
  performance improvements.

Increment:

- **major**: increment `B`, reset `C` and `D` to 0 (`0.1.0.0` → `0.2.0.0`).
- **minor**: increment `C`, reset `D` to 0 (`0.1.0.0` → `0.1.1.0`).
- **patch**: increment `D` (`0.1.0.0` → `0.1.0.1`).

Each package carries its own version and its own release history.

## Arguments

`$ARGUMENTS` is optional:

- `major`, `minor`, or `patch` — forces the bump level.
- If omitted, infer the bump level from the changes (step 3).

## Steps

### 1. Choose which package to release

If the user named a package, use it. Otherwise:

- For each package (`kansoku-api`, `kansoku-client`, `kansoku-core`,
  `kansoku-server`), find its latest tag matching `<pkg>-*` and run
  `git log --oneline <last-tag>..HEAD -- <pkg>/` to see whether it changed
  since its last release. For a never-released package there will be no tag —
  treat the whole history of its directory as the first release.
- Present which packages have changes (note each one's track) and ask the user
  which to release now. If releasing several, do them in dependency order:
  `kansoku-api` → `kansoku-client`, and `kansoku-core` → `kansoku-server`.

If a package has no commits touching its directory since its last tag, tell the
user there is nothing to release for it and skip it.

### 2. Determine what changed

For the chosen package:

- Read its current version from `<pkg>/<pkg>.cabal`.
- List commits since its last tag that touch `<pkg>/` (and shared code it
  depends on — e.g. a `kansoku-client` or `kansoku-core` release should account
  for relevant `kansoku-api/` changes, and `kansoku-server` for
  `kansoku-core/`).

Present: current version, last tag (or "none — first release"), and the commit
summary.

### 3. Compute the next version (PVP)

- If `$ARGUMENTS` is `major`/`minor`/`patch`, use it.
- Otherwise infer from the commits:
  - "breaking", "remove", "rename", "change type", `!`/`BREAKING CHANGE` → major
  - "add", "new", "feature", "export", "expose" → minor
  - "fix", "docs", "refactor", "internal", "perf" → patch
- Present the proposed version and **ask the user to confirm** before editing
  anything.

### 4. Update version, internal bounds, and changelog

#### Version

- Edit `<pkg>/<pkg>.cabal` to set the new `version:`.

#### Internal dependency bounds (Hackage track only)

Only matters when publishing a library that another published library depends
on. `kansoku-client/kansoku-client.cabal` currently depends on `kansoku-api`
with **no version bound**, in both the `library` and the `kansoku-client-test`
test-suite `build-depends`. Before publishing `kansoku-client`, add a
PVP-compatible bound to **both** occurrences:

```
kansoku-api ^>=A.B.C.D
```

matching the currently published `kansoku-api` version. If you are releasing a
new `kansoku-api` in the same session, release it first, then set
`kansoku-client`'s bound to that new version. (`kansoku-core` and
`kansoku-server` are tag-only, so their internal bounds need not be
PVP-tightened for Hackage.)

#### Changelog

No package has a `CHANGELOG.md` yet. Maintain a **per-package**
`<pkg>/CHANGELOG.md` for every released package (both tracks):

- If it does not exist, create it with a top header and the first version
  section.
- Otherwise add a new section for the new version **above** previous entries.
- Use today's date in `YYYY-MM-DD` format.
- Group entries under only the categories that apply: **Breaking Changes**
  (major), **New Features** (minor/major), **Bug Fixes**, **Other Changes**.
- For a **Hackage-track** package, add `changelog: CHANGELOG.md` to the cabal
  file (or `extra-source-files`) so the changelog ships in the sdist, if it is
  not already referenced.

Show the user **all** changes (version, bounds, changelog) for review before
committing.

### 5. Verify (never skip these gates)

Run from the repo root inside `nix develop`:

- `just format-check` — formatting gate (`nix fmt -- --fail-on-change`,
  treefmt + fourmolu).
- `cabal build <pkg>` — build the package and its components.
- Run the relevant test suite:
  - **kansoku-api** — no test suite of its own; skip.
  - **kansoku-client** — `cabal test kansoku-client-test`.
  - **kansoku-core** — `cabal test kansoku-core-test`.
  - **kansoku-server** — most server test-suites are gated behind manual flags
    (`native-migration-tests`, `migration-acceptance-probe`) and require live
    stores; at minimum confirm the executables build. Use `just check` for the
    non-ambient-database gate if the change warrants it.
- `cabal check` from inside `<pkg>/` — **Hackage-track packages only**
  (packaging sanity for the sdist). Not required for tag-only packages.
- `nix flake check` — treefmt + pre-commit gates. Newly created files
  (e.g. a brand-new `CHANGELOG.md`) must be `git add`-ed first, because Nix
  evaluates from the git tree.

If any gate fails, fix it before proceeding. Do not continue on failure.

### 6. Commit, tag, and push (all packages, both tracks)

- Stage the modified `<pkg>/<pkg>.cabal`, `<pkg>/CHANGELOG.md`, and (for
  `kansoku-client`) the bound change.
- Commit with a Conventional Commits message scoped to the package:
  `chore(release): <pkg>-<version>`. The body summarizes the release and why
  this bump level.
- Create an **annotated per-package** tag:
  `git tag -a <pkg>-<version> -m "<pkg> <version>"`.
- Push: `git push && git push --tags`.

If releasing several packages, make a separate commit and tag per package, in
dependency order.

### 7. Publish to Hackage (Hackage track only, in dependency order)

**Skip this step entirely for `kansoku-core` and `kansoku-server`.**

For each Hackage-track package being released (`kansoku-api` before
`kansoku-client`):

1. `cd <pkg>/`
2. `cabal check` — confirm no packaging issues.
3. `cabal sdist` then `cabal upload --publish <tarball-path>` to publish the
   source distribution.
4. `cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump`
   then `cabal upload --publish --documentation <docs-tarball-path>` to publish
   the docs.
5. Report the Hackage URL:
   `https://hackage.haskell.org/package/<pkg>-<version>`.

> `cabal upload` needs Hackage credentials (a `~/.config/cabal/config` upload
> token or `--username`/`--password`). If the upload is unauthenticated, stop
> and ask the user to configure credentials rather than retrying blindly.

Present a summary table for the uploaded packages:

| Package | Version | Hackage URL |
|---------|---------|-------------|
| kansoku-api | X.Y.Z.W | https://hackage.haskell.org/package/kansoku-api-X.Y.Z.W |

### 8. Create the GitHub release (all packages, both tracks)

After step 6 (and, for Hackage-track packages, after their upload in step 7
succeeds), create a GitHub release for each tag:

```bash
gh release create <pkg>-<version> --title "<pkg> <version>" --notes "$(cat <<'EOF'
## What's Changed

<the new section from <pkg>/CHANGELOG.md>
EOF
)"
```

For a **Hackage-track** package, add a Hackage link above the changelog:

```
## Hackage

https://hackage.haskell.org/package/<pkg>-<version>
```

For **kansoku-server**, note in the body that the runnable distribution is the
TAN container image, not this source tag. Report the GitHub release URL for
each package.

## Important

- Only **kansoku-api** and **kansoku-client** are uploaded to Hackage.
  **kansoku-core** and **kansoku-server** are tag-and-GitHub-release only —
  never `cabal upload` them without explicit user confirmation of a scope
  change.
- All four packages get a version bump, changelog, annotated git tag
  (`<pkg>-<version>`), and GitHub release.
- Always ask the user to confirm the version bump and changelog **before**
  committing. The commit and tag are created only after approval.
- Release in dependency order: `kansoku-api` → `kansoku-client`, and
  `kansoku-core` → `kansoku-server`.
- Before publishing `kansoku-client`, ensure its `kansoku-api` bound is set to
  a PVP range in both the library and test-suite sections.
- Never skip `just format-check`, `cabal build`, the relevant test suite, or
  `nix flake check`. For Hackage-track packages also run `cabal check`.
- Stop and report on any failure. If a Hackage upload fails for `kansoku-api`,
  do **not** continue publishing `kansoku-client`, which depends on it.
