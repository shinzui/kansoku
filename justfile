# Kansoku developer commands. Run inside `nix develop`.

# Create the `kansoku` PostgreSQL database if it does not already exist.
# process-compose.yaml's `create_schema` process runs this after postgres is healthy.
create-database:
    @if psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'kansoku'" | grep -q 1; then \
        echo "database 'kansoku' already exists"; \
    else \
        createdb kansoku && echo "created database 'kansoku'"; \
    fi

# Build everything (library, server, tests).
build:
    cabal build all

# Run the unit tests.
test:
    cabal test all

# Regenerate the checked-in OpenAPI document from the served route types.
openapi:
    cabal run kansoku-openapi

# Fail if the checked-in OpenAPI document is stale.
openapi-check:
    python3 scripts/check-generated.py openapi

# Regenerate the committed event contract artifact from the registry.
contracts:
    cabal run kansoku-contracts

# Fail if the committed event contract artifact is stale.
contracts-check:
    python3 scripts/check-generated.py contracts

# Enforce the shared architecture-decision profile and log freshness for docs/adr.
adr-check:
    okf validate docs/adr --profile docs/adr/profile.dhall --profile-enforce --log-enforce

# Enforce the shared review profile and log freshness for docs/reviews.
reviews-check:
    okf validate docs/reviews --strict --profile docs/reviews/profile.dhall --profile-enforce --log-enforce

# Enforce required capability metadata; independent reviews remain recommended.
capabilities-check:
    okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce

# Enforce controlled vocabulary metadata, term references and log freshness.
terminology-check:
    okf validate docs/terminology --strict --profile docs/terminology/profile.dhall --profile-enforce --log-enforce

# Apply unapplied ClickHouse migrations in filename order, recording each in
# analytics.schema_migrations. Migration files are immutable once applied.
ch-migrate:
    ./db/clickhouse/migrate.sh

# Drop the analytics database (including the migration ledger) and replay all
# migrations from scratch. Dev-only; destroys all analytics data.
ch-reset:
    clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "DROP DATABASE IF EXISTS analytics"
    ./db/clickhouse/migrate.sh

# Load the EP-5 ClickHouse verification fixtures.
ch-fixtures-ep5:
    clickhouse-client --port $CLICKHOUSE_TCP_PORT --multiquery < db/clickhouse/fixtures/ep5_fixtures.sql

# Load the EP-6 semantic metrics verification fixtures.
ch-fixtures-ep6:
    clickhouse-client --port $CLICKHOUSE_TCP_PORT --multiquery < db/clickhouse/fixtures/ep6_fixtures.sql

# Load the EP-18 multi-signal identity fixtures.
ch-fixtures-ep18:
    clickhouse-client --port $CLICKHOUSE_TCP_PORT --multiquery < db/clickhouse/fixtures/ep18_fixtures.sql

# Load the EP-18 conflict phase after ch-fixtures-ep18.
ch-fixtures-ep18-conflict:
    clickhouse-client --port $CLICKHOUSE_TCP_PORT --multiquery < db/clickhouse/fixtures/ep18_conflict.sql

# Load the EP-19 experiment analytics verification fixtures.
ch-fixtures-ep19:
    clickhouse-client --port $CLICKHOUSE_TCP_PORT --multiquery < db/clickhouse/fixtures/ep19_fixtures.sql

# Run the HTTP server.
run: migrate
    cabal run kansoku-server:exe:kansoku-server

# Apply Kansoku's explicit PostgreSQL migration plan.
migrate:
    cabal run kansoku-migrate -- up

# Issue an API key after applying the explicit PostgreSQL migration plan.
issue-key kind account description="": migrate
    cabal run kansoku-server:exe:kansoku-server -- issue-key --kind {{kind}} --account {{account}} --description "{{description}}"

# Bootstrap one browser write key and one service token for local development.
dev-keys: migrate
    cabal run kansoku-server:exe:kansoku-server -- issue-key --kind write --account dev --description "local dev write key"
    cabal run kansoku-server:exe:kansoku-server -- issue-key --kind service --account dev --description "local dev service token"

# Start the local services (postgres, clickhouse, create_schema) via process-compose.
up:
    process-compose --port "${PC_PORT_NUM:-8081}" up

# Build every local component, including test executables.
build-with-tests:
    cabal build all --enable-tests

# Non-mutating source formatting gate.
format-check:
    nix fmt -- --fail-on-change

# Deterministic subsets explicitly exclude native/live families and fail pending cases.
deterministic-test:
    python3 scripts/deterministic-tests.py

# Validate OpenAPI 3.1 with the linter pinned by flake.lock.
openapi-lint:
    vacuum lint --no-update-check --fail-severity error docs/api/openapi.json

# Developer/CI gate without ambient database dependencies.
check: build-with-tests format-check deterministic-test openapi-check contracts-check openapi-lint capabilities-check terminology-check
    okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
    python3 scripts/http-telemetry.py

# Safe, read-only resource families against an already-running loopback service.
hurl:
    bash kansoku-api/test/hurl/run.sh

# Own private databases and exercise the Nix-packaged executable.
acceptance:
    bash scripts/acceptance.sh

# Required EP-30 duration proof: owned stores, packaged server, 600s at 200 events/s.
outage-acceptance:
    python3 scripts/outage-acceptance.py

# Shorter native outage/restart proof for recovery-code changes.
outage-smoke:
    python3 scripts/outage-acceptance.py --smoke

# Exercise the Mori-registered browser SDK against the 429 transport contract.
sdk-rate-limit:
    python3 scripts/sdk-rate-limit.py

# Own a scratch ClickHouse and verify conservative identity semantics and rebuilds.
identity-acceptance: build-with-tests
    python3 scripts/identity_acceptance.py

# Required EP-32 cost gate: ten million events and five measured runs per case.
identity-bench:
    python3 scripts/identity-bench.py

# Own disposable stores and verify public cohort management and metric selection.
cohorts-acceptance: build-with-tests
    python3 scripts/cohorts_acceptance.py

# Own a scratch ClickHouse and verify bounded paths, page flows and reverse traversal.
paths-acceptance: build-with-tests
    python3 scripts/paths-acceptance.py

# Own disposable stores and verify custom metrics and saved definitions.
custom-metrics-acceptance: build-with-tests
    python3 scripts/custom_metrics_acceptance.py

# Own disposable stores and verify organisation metrics, traits and membership.
organizations-acceptance: build-with-tests
    python3 scripts/organizations_acceptance.py
