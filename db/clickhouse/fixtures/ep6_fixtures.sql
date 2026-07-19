-- EP-6 metrics fixtures. The duplicate e2 row verifies that raw-table event
-- counts remain replay-proof: count(DISTINCT event_id) returns three page views
-- on 2026-06-01. The page-views rollup intentionally counts inserted rows, so
-- countMerge reports four; OPTIMIZE collapses the raw replay but cannot retract
-- the already-recorded count state. This is the accepted count-state tradeoff.
-- User u4 deliberately completes signup before starting it. The ordered funnel
-- counts u1/u3/u4 at step 1 (3) but only u1 at step 2 (1).
INSERT INTO analytics.events_raw
  (event_id, event_name, source, occurred_at, received_at, user_id, url, session_id, account_id, properties, context)
VALUES
  ('e1','page_view','web','2026-06-01 09:00:00','2026-06-01 09:00:00','u1','/home','s1','acct-legacy','{}','{}'),
  ('e2','page_view','web','2026-06-01 10:00:00','2026-06-01 10:00:00','u2','/home','s2','acct-legacy','{}','{}'),
  ('e3','page_view','web','2026-06-01 11:00:00','2026-06-01 11:00:00','u1','/pricing','s1','acct-legacy','{}','{}'),
  ('e4','signup_started','web','2026-06-01 11:05:00','2026-06-01 11:05:00','u1','/signup','s1','acct-legacy','{}','{}'),
  ('e5','signup_completed','web','2026-06-01 11:10:00','2026-06-01 11:10:00','u1','/welcome','s1','acct-legacy','{}','{}'),
  ('e6','signup_started','web','2026-06-02 09:00:00','2026-06-02 09:00:00','u3','/signup','s3','acct-legacy','{}','{}'),
  ('e7','page_view','web','2026-06-02 09:30:00','2026-06-02 09:30:00','u3','/home','s3','acct-legacy','{}','{}'),
  ('e8','feature_used','web','2026-06-02 10:00:00','2026-06-02 10:00:00','u1','/app','s4','acct-legacy','{}','{}'),
  ('e9','feature_used','web','2026-06-03 10:00:00','2026-06-03 10:00:00','u3','/app','s5','acct-legacy','{}','{}'),
  ('e10','signup_completed','web','2026-06-03 09:00:00','2026-06-03 09:00:00','u4','/welcome','s6','acct-legacy','{}','{}'),
  ('e11','signup_started','web','2026-06-03 10:00:00','2026-06-03 10:00:00','u4','/signup','s6','acct-legacy','{}','{}'),
  ('e2','page_view','web','2026-06-01 10:00:00','2026-06-01 10:00:00','u2','/home','s2','acct-legacy','{}','{}');

OPTIMIZE TABLE analytics.events_raw FINAL;
