-- EP-18 fixture: two sessions, one fingerprint, one identify. The control
-- account tells the same story without fingerprints.
INSERT INTO analytics.events_raw
    (event_id, event_name, source, occurred_at, received_at, account_id, anonymous_id, user_id, url, properties, context, identifiers)
VALUES
    ('s-a1', 'page_view',    'web', '2026-07-01 09:00:00.000', '2026-07-01 09:00:00.100', 'acct-1',   'anon-A',  '',        'https://app.example.com/pricing', '{}', '{}', '{"fingerprint":"fp-F"}'),
    ('s-a2', 'page_view',    'web', '2026-07-01 09:05:00.000', '2026-07-01 09:05:00.100', 'acct-1',   'anon-A',  '',        'https://app.example.com/signup',  '{}', '{}', '{"fingerprint":"fp-F"}'),
    ('s-id', 'identify',     'web', '2026-07-01 09:10:00.000', '2026-07-01 09:10:00.100', 'acct-1',   'anon-A',  'user-U',  '',                                '{}', '{}', '{"fingerprint":"fp-F"}'),
    ('s-b1', 'page_view',    'web', '2026-07-01 10:00:00.000', '2026-07-01 10:00:00.100', 'acct-1',   'anon-B',  '',        'https://app.example.com/docs',    '{}', '{}', '{"fingerprint":"fp-F"}'),
    ('s-b2', 'feature_used', 'app', '2026-07-01 10:05:00.000', '2026-07-01 10:05:00.100', 'acct-1',   'anon-B',  '',        '',                                '{}', '{}', '{"fingerprint":"fp-F"}'),
    ('c-a1', 'page_view',    'web', '2026-07-01 09:00:00.000', '2026-07-01 09:00:00.100', 'acct-ctl', 'anon-CA', '',        'https://app.example.com/pricing', '{}', '{}', '{}'),
    ('c-a2', 'page_view',    'web', '2026-07-01 09:05:00.000', '2026-07-01 09:05:00.100', 'acct-ctl', 'anon-CA', '',        'https://app.example.com/signup',  '{}', '{}', '{}'),
    ('c-id', 'identify',     'web', '2026-07-01 09:10:00.000', '2026-07-01 09:10:00.100', 'acct-ctl', 'anon-CA', 'user-CU', '',                                '{}', '{}', '{}'),
    ('c-b1', 'page_view',    'web', '2026-07-01 10:00:00.000', '2026-07-01 10:00:00.100', 'acct-ctl', 'anon-CB', '',        'https://app.example.com/docs',    '{}', '{}', '{}'),
    ('c-b2', 'feature_used', 'app', '2026-07-01 10:05:00.000', '2026-07-01 10:05:00.100', 'acct-ctl', 'anon-CB', '',        '',                                '{}', '{}', '{}');
