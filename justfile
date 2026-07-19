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
    cabal run kansoku-openapi
    git diff --exit-code docs/api/openapi.json

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
    process-compose up
