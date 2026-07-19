-- EP-18 conflict fixture: fingerprint fp-F is later observed with user-V.
INSERT INTO analytics.events_raw
    (event_id, event_name, source, occurred_at, received_at, account_id, anonymous_id, user_id, url, properties, context, identifiers)
VALUES
    ('s-v', 'identify', 'web', '2026-07-01 11:00:00.000', '2026-07-01 11:00:00.100', 'acct-1', 'anon-C', 'user-V', '', '{}', '{}', '{"fingerprint":"fp-F"}');
