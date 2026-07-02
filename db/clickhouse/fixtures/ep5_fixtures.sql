-- EP-5 rollup fixtures. All events on 2026-06-08 (a Monday), so day = week = 2026-06-08.
-- The identify event is inserted FIRST so the DAU/WAU MVs resolve anon-2 -> user-10
-- at insert time (deterministic, common ordering).
-- f7 is a NEVER-identified visitor (anon-3, no identify anywhere): it must count
-- as one DAU/WAU actor under its own anonymous id. If it vanishes from DAU, the
-- join_use_nulls trap has regressed.
INSERT INTO analytics.events_raw
    (event_id, event_name, source, occurred_at, received_at, anonymous_id, user_id, url)
VALUES
    ('f-id', 'identify', 'app', '2026-06-08 08:00:00.000', '2026-06-08 08:00:00.100', 'anon-2', 'user-10', '');

INSERT INTO analytics.events_raw
    (event_id, event_name, source, occurred_at, received_at, anonymous_id, user_id, url)
VALUES
    ('f1', 'page_view', 'web', '2026-06-08 09:00:00.000', '2026-06-08 09:00:00.100', 'anon-2', '', 'https://app.example.com/pricing'),
    ('f2', 'page_view', 'web', '2026-06-08 09:01:00.000', '2026-06-08 09:01:00.100', 'anon-2', '', 'https://app.example.com/signup?ref=x'),
    ('f3', 'page_view', 'app', '2026-06-08 09:05:00.000', '2026-06-08 09:05:00.100', 'anon-2', 'user-10', 'https://app.example.com/dashboard'),
    ('f4', 'feature_used', 'app', '2026-06-08 09:06:00.000', '2026-06-08 09:06:00.100', 'anon-2', 'user-10', ''),
    ('f5', 'page_view', 'web', '2026-06-08 10:00:00.000', '2026-06-08 10:00:00.100', 'anon-9', 'user-20', 'https://app.example.com/pricing'),
    ('f6', 'feature_used', 'app', '2026-06-08 10:05:00.000', '2026-06-08 10:05:00.100', '', 'user-20', ''),
    ('f7', 'page_view', 'web', '2026-06-08 11:00:00.000', '2026-06-08 11:00:00.100', 'anon-3', '', 'https://app.example.com/docs');
