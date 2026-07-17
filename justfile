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
    cabal test

# Apply ClickHouse migrations in filename order.
ch-migrate:
    for f in db/clickhouse/migrations/*.sql; do echo "applying $f"; clickhouse-client --port $CLICKHOUSE_TCP_PORT --multiquery < "$f"; done

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
