-- EP-19 fixture: exposure counts, post-exposure conversion ordering, ordered
-- funnel progress, re-exposure deduplication, and account isolation.
INSERT INTO analytics.events_raw
    (event_id, event_name, source, occurred_at, received_at, account_id, user_id, properties, context)
VALUES
    ('exp-a-c1', 'experiment_viewed', 'web', '2026-08-01 10:00:00.000', '2026-08-01 10:00:00.100', 'acct_a', 'c1', '{"experiment":"checkout_v2","variant":"control"}', '{}'),
    ('exp-a-c2', 'experiment_viewed', 'web', '2026-08-01 10:00:00.000', '2026-08-01 10:00:00.100', 'acct_a', 'c2', '{"experiment":"checkout_v2","variant":"control"}', '{}'),
    ('exp-a-c3', 'experiment_viewed', 'web', '2026-08-01 10:00:00.000', '2026-08-01 10:00:00.100', 'acct_a', 'c3', '{"experiment":"checkout_v2","variant":"control"}', '{}'),
    ('exp-a-c4', 'experiment_viewed', 'web', '2026-08-01 10:00:00.000', '2026-08-01 10:00:00.100', 'acct_a', 'c4', '{"experiment":"checkout_v2","variant":"control"}', '{}'),
    ('exp-a-c5', 'experiment_viewed', 'web', '2026-08-01 10:00:00.000', '2026-08-01 10:00:00.100', 'acct_a', 'c5', '{"experiment":"checkout_v2","variant":"control"}', '{}'),
    ('exp-a-t1', 'experiment_viewed', 'web', '2026-08-01 10:00:00.000', '2026-08-01 10:00:00.100', 'acct_a', 't1', '{"experiment":"checkout_v2","variant":"treatment"}', '{}'),
    ('exp-a-t2', 'experiment_viewed', 'web', '2026-08-01 10:00:00.000', '2026-08-01 10:00:00.100', 'acct_a', 't2', '{"experiment":"checkout_v2","variant":"treatment"}', '{}'),
    ('exp-a-t3', 'experiment_viewed', 'web', '2026-08-01 10:00:00.000', '2026-08-01 10:00:00.100', 'acct_a', 't3', '{"experiment":"checkout_v2","variant":"treatment"}', '{}'),
    ('exp-a-t4', 'experiment_viewed', 'web', '2026-08-01 10:00:00.000', '2026-08-01 10:00:00.100', 'acct_a', 't4', '{"experiment":"checkout_v2","variant":"treatment"}', '{}'),
    ('exp-a-t5', 'experiment_viewed', 'web', '2026-08-01 10:00:00.000', '2026-08-01 10:00:00.100', 'acct_a', 't5', '{"experiment":"checkout_v2","variant":"treatment"}', '{}'),
    ('exp-a-c1-again', 'experiment_viewed', 'web', '2026-08-02 10:00:00.000', '2026-08-02 10:00:00.100', 'acct_a', 'c1', '{"experiment":"checkout_v2","variant":"control"}', '{}'),
    ('checkout-a-c1', 'checkout_started', 'web', '2026-08-01 11:00:00.000', '2026-08-01 11:00:00.100', 'acct_a', 'c1', '{}', '{}'),
    ('checkout-a-t1', 'checkout_started', 'web', '2026-08-01 11:00:00.000', '2026-08-01 11:00:00.100', 'acct_a', 't1', '{}', '{}'),
    ('checkout-a-t2', 'checkout_started', 'web', '2026-08-01 11:00:00.000', '2026-08-01 11:00:00.100', 'acct_a', 't2', '{}', '{}'),
    ('checkout-a-t3', 'checkout_started', 'web', '2026-08-01 11:00:00.000', '2026-08-01 11:00:00.100', 'acct_a', 't3', '{}', '{}'),
    ('checkout-a-t4', 'checkout_started', 'web', '2026-08-01 11:00:00.000', '2026-08-01 11:00:00.100', 'acct_a', 't4', '{}', '{}'),
    ('purchase-a-c2-before', 'purchase_completed', 'web', '2026-08-01 09:00:00.000', '2026-08-01 09:00:00.100', 'acct_a', 'c2', '{}', '{}'),
    ('purchase-a-c1', 'purchase_completed', 'web', '2026-08-01 12:00:00.000', '2026-08-01 12:00:00.100', 'acct_a', 'c1', '{}', '{}'),
    ('purchase-a-t1', 'purchase_completed', 'web', '2026-08-01 12:00:00.000', '2026-08-01 12:00:00.100', 'acct_a', 't1', '{}', '{}'),
    ('purchase-a-t2', 'purchase_completed', 'web', '2026-08-01 12:00:00.000', '2026-08-01 12:00:00.100', 'acct_a', 't2', '{}', '{}'),
    ('purchase-a-t3', 'purchase_completed', 'web', '2026-08-01 12:00:00.000', '2026-08-01 12:00:00.100', 'acct_a', 't3', '{}', '{}'),
    ('exp-b-b1', 'experiment_viewed', 'web', '2026-08-01 10:00:00.000', '2026-08-01 10:00:00.100', 'acct_b', 'b1', '{"experiment":"checkout_v2","variant":"control"}', '{}'),
    ('exp-b-b2', 'experiment_viewed', 'web', '2026-08-01 10:00:00.000', '2026-08-01 10:00:00.100', 'acct_b', 'b2', '{"experiment":"checkout_v2","variant":"control"}', '{}');
