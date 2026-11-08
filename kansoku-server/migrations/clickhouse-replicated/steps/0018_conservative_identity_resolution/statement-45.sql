
INSERT INTO analytics.dau_rebuild (account_id,day,users)
SELECT account_id, toDate(occurred_at) AS day, uniqCombinedState(if(user_id!='',concat('user:',user_id),concat('anonymous:',anonymous_id))) AS users
FROM analytics.events_canonical WHERE user_id != '' OR anonymous_id != ''
GROUP BY account_id, day;