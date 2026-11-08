

INSERT INTO analytics.dau (account_id, day, users)
SELECT
    account_id,
    toDate(occurred_at) AS day,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY account_id, day;