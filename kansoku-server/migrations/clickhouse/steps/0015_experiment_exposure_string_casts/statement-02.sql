

CREATE MATERIALIZED VIEW analytics.mv_experiment_exposures
TO analytics.experiment_exposures
AS
SELECT
    account_id,
    CAST(toString(getSubcolumn(properties_json, 'experiment')), 'String') AS experiment,
    CAST(toString(getSubcolumn(properties_json, 'variant')), 'String') AS variant,
    toDate(occurred_at) AS day,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE event_name = 'experiment_viewed'
  AND (user_id != '' OR anonymous_id != '')
  AND match(CAST(toString(getSubcolumn(properties_json, 'experiment')), 'String'), '^[a-z0-9_.:-]{1,128}$')
  AND match(CAST(toString(getSubcolumn(properties_json, 'variant')), 'String'), '^[a-z0-9_.:-]{1,128}$')
GROUP BY account_id, experiment, variant, day;
