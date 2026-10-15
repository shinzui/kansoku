# Executable HTTP contracts

Inside `nix develop`, `just acceptance` builds the Nix server and client, creates fresh
PostgreSQL and ClickHouse processes, applies both migration sets, runs required native tests,
issues disposable credentials, seeds fixtures and executes these files. It also runs the live
SDK case, native failure/recovery watchdogs and complete console-span privacy checks in legacy,
`http` and `http/dup` modes. Missing prerequisites and pending required cases fail acceptance.

ADR validation uses an immutable OKF 0.10.0.0 release-flake launcher, so a host OKF
installation is unnecessary.

Each run owns `.dev/acceptance/run-*/`, including private logs, data and a mode-600 secrets file.
Cleanup stops only its recorded children on success, failure, INT or TERM. The directory is
retained for diagnosis. CI uploads only `sanitized/*.log`; never upload the raw directory.
`KANSOKU_ACCEPTANCE_ROOT` may select a local parent directory; a fresh child is always created.
No inherited database URL, exporter or credential is used. PostgreSQL, ClickHouse, Hurl,
Python, Cabal and Nix come from the locked development shell.

For an already running disposable loopback server:

```bash
KANSOKU_HURL_BASE_URL=http://127.0.0.1:8080 \
KANSOKU_HURL_SECRETS_FILE=/absolute/private/secrets.env just hurl
```

The safe runner explicitly selects health, OpenAPI, schemas and read-only metrics. It requires
`service_token` and `highcard_token` in the Hurl secrets file (`name=value`, chmod 600).
`vars.env` contains only nonsecret dates and a local default URL. It rejects remote URLs.
Never select all files with a glob: ingest and perimeter require explicit opt-in.

Fixtures use July 1–12, 2026. The metrics account has two users, page views and sessions,
signup starts, a completed signup, feature usage, amount-7 payment and two experiment variants.
The account contains only those fixture rows: July 1 has eight distinct events,
three page views, two sessions and two users; July 2 has one feature user, a payment of 7
and one page view. Signup conversion is 0.5 and ordered funnel counts are 2 then 1.
`seed` in `scripts/acceptance.py` defines the exact rows. These distinguish route meanings. A separate high-cardinality account needs 10,001 payment
property groups and experiment variants. The harness seeds both. The ingest file needs a fresh
account with write/service keys, an unrelated read account, unique event ID, allowed origin
`https://allowed.example`, a 4096-byte body limit and an oversized-file variable. It submits one
partial batch exactly once and retries only the observing GET. Perimeter also needs a write key
for the metrics account. `metrics-disabled.hurl` runs against a separate metrics-disabled server.

Every request checks status and stable wire meaning, including problem codes, numeric status,
media types and browser-visible CORS behavior. Disallowed origins retain the CORS
middleware's 400 HTML rejection without an allow-origin header; allowed-origin API
failures carry the shared problem JSON. Changing fixture semantics requires updating the
fixture and corresponding assertions together. No production credential belongs in this tree.
