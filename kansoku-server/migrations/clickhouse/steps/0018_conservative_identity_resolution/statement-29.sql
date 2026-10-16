

-- Identity depends on a context, not each individual event. Keep an exact
-- replay-safe per-day signal index so repeated session activity does not need
-- raw JSON expansion on every read. Raw candidates still bound returned facts.
DROP TABLE IF EXISTS analytics.mv_identity_context_signals;