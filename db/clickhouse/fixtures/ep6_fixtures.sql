-- EP-6 metrics fixtures. The duplicate e2 row verifies that raw-table event
-- counts remain replay-proof: count(DISTINCT event_id) returns three page views
-- on 2026-06-01. The page-views rollup intentionally counts inserted rows, so
-- countMerge reports four; OPTIMIZE collapses the raw replay but cannot retract
-- the already-recorded count state. This is the accepted count-state tradeoff.
INSERT INTO analytics.events_raw
  (event_id, event_name, source, occurred_at, received_at, user_id, url, session_id)
VALUES
  ('e1','page_view','web','2026-06-01 09:00:00','2026-06-01 09:00:00','u1','/home','s1'),
  ('e2','page_view','web','2026-06-01 10:00:00','2026-06-01 10:00:00','u2','/home','s2'),
  ('e3','page_view','web','2026-06-01 11:00:00','2026-06-01 11:00:00','u1','/pricing','s1'),
  ('e4','signup_started','web','2026-06-01 11:05:00','2026-06-01 11:05:00','u1','/signup','s1'),
  ('e5','signup_completed','web','2026-06-01 11:10:00','2026-06-01 11:10:00','u1','/welcome','s1'),
  ('e6','signup_started','web','2026-06-02 09:00:00','2026-06-02 09:00:00','u3','/signup','s3'),
  ('e7','page_view','web','2026-06-02 09:30:00','2026-06-02 09:30:00','u3','/home','s3'),
  ('e8','feature_used','web','2026-06-02 10:00:00','2026-06-02 10:00:00','u1','/app','s4'),
  ('e9','feature_used','web','2026-06-03 10:00:00','2026-06-03 10:00:00','u3','/app','s5'),
  ('e2','page_view','web','2026-06-01 10:00:00','2026-06-01 10:00:00','u2','/home','s2');

OPTIMIZE TABLE analytics.events_raw FINAL;
