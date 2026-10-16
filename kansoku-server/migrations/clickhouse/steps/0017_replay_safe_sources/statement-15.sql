

-- Each swap is atomic. The writer stays stopped across both. On interruption,
-- discard/rebuild the temporary tables and swap again from canonical data;
-- this works whether the public name has its old or its replacement schema.
EXCHANGE TABLES analytics.daily_event_counts AND analytics.daily_event_counts_rebuild;