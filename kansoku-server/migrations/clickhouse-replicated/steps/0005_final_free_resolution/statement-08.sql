

INSERT INTO analytics.wau (week, users)
SELECT
    toMonday(occurred_at) AS week,
    uniqExactState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY week;