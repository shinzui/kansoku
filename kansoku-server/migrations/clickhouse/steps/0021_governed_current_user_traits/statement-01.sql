-- EP-40: governed current traits. Keep ingest/writers fenced during DDL/rebuilds.
-- Identify v1 is identity-only. Eligibility mirrors the shared registry and
-- checks actual stored schema_version and the immutable server validation marker.
-- Exact decimal integrality is validated before Float64/native JSON conversion.
-- Strings are stored decoded; numeric values use the metrics Float64 contract.
ALTER TABLE analytics.events_raw ADD COLUMN IF NOT EXISTS governed_traits_valid Bool DEFAULT false;