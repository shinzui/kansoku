
CREATE MATERIALIZED VIEW analytics.mv_experiment_exposures TO analytics.experiment_exposures AS
SELECT account_id, toDate(occurred_at) AS day, CAST(toString(getSubcolumn(properties_json, 'experiment')), 'String') AS experiment, CAST(toString(getSubcolumn(properties_json, 'variant')), 'String') AS variant, uniqCombinedState(if(user_id!='',concat('user:',user_id),concat('anonymous:',anonymous_id))) AS users
FROM analytics.events_raw WHERE event_name = 'experiment_viewed' AND (user_id != '' OR anonymous_id != '') AND match(experiment, '^[a-z0-9_.:-]{1,128}$') AND match(variant, '^[a-z0-9_.:-]{1,128}$')
GROUP BY account_id, experiment, variant, day;