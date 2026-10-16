
CREATE MATERIALIZED VIEW analytics.mv_wau TO analytics.wau AS
SELECT account_id, toMonday(occurred_at) AS week, uniqCombinedState(if(user_id!='',concat('user:',user_id),concat('anonymous:',anonymous_id))) AS users
FROM analytics.events_raw WHERE user_id != '' OR anonymous_id != ''
GROUP BY account_id, week;