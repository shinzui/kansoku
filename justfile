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

# Run the HTTP server.
run: migrate
    cabal run kansoku-server

# Apply Kansoku's explicit PostgreSQL migration plan.
migrate:
    cabal run kansoku-migrate -- up

# Start the local services (postgres, clickhouse, create_schema) via process-compose.
up:
    process-compose up
