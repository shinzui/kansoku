

-- Inserts made between the backfill above and this trigger creation are not
-- observed. EP-19 lands before production experiment traffic; in development,
-- reset and replay migrations if that window matters.
CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_experiment_exposures
TO analytics.experiment_exposures
AS
SELECT
    account_id,
    toString(getSubcolumn(properties_json, 'experiment')) AS experiment,
    toString(getSubcolumn(properties_json, 'variant')) AS variant,
    toDate(occurred_at) AS day,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE event_name = 'experiment_viewed'
  AND (user_id != '' OR anonymous_id != '')
  AND match(toString(getSubcolumn(properties_json, 'experiment')), '^[a-z0-9_.:-]{1,128}$')
  AND match(toString(getSubcolumn(properties_json, 'variant')), '^[a-z0-9_.:-]{1,128}$')
GROUP BY account_id, experiment, variant, day;
