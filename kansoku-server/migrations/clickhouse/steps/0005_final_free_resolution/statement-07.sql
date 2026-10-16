

INSERT INTO analytics.dau (day, users)
SELECT
    toDate(occurred_at) AS day,
    uniqExactState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY day;