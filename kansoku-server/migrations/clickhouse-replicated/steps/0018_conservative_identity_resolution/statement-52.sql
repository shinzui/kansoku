
INSERT INTO analytics.wau_rebuild (account_id,week,users)
SELECT account_id, toMonday(occurred_at) AS week, uniqCombinedState(if(user_id!='',concat('user:',user_id),concat('anonymous:',anonymous_id))) AS users
FROM analytics.events_canonical WHERE user_id != '' OR anonymous_id != ''
GROUP BY account_id, week;