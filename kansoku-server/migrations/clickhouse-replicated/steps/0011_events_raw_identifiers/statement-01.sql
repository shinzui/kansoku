-- EP-18 M1: persist the identifiers map (kind -> value) on raw events.
-- The ClickHaskell wire carries a JSON-object String; '{}' keeps old rows
-- valid for server-side JSON extraction without rewriting existing parts.
ALTER TABLE analytics.events_raw
    ADD COLUMN IF NOT EXISTS identifiers String DEFAULT '{}' AFTER context;
