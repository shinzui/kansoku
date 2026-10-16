-- Configure GrowthBook's identifier as user_id. Keep one row per canonical
-- exposure event, including identical re-exposure tuples with distinct IDs.
WITH exposures AS MATERIALIZED
(
    SELECT * FROM analytics.events_analytics_v1(account={account:String},
        from_time={from_time:DateTime64(3,'UTC')}, to_time={to_time:DateTime64(3,'UTC')})
    WHERE source_service={source_service:String} AND canonical_user!=''
      AND event_name='experiment_viewed'
      AND dynamicElement(getSubcolumn(properties_json,'experiment'),'String')={experiment:String}
      AND match(dynamicElement(getSubcolumn(properties_json,'experiment'),'String'),'^[a-z0-9_.:-]{1,128}$')
      AND match(dynamicElement(getSubcolumn(properties_json,'variant'),'String'),'^[a-z0-9_.:-]{1,128}$')
), map('control','0','variant_b','1') AS variations
SELECT canonical_user AS user_id,
       occurred_at AS timestamp,
       dynamicElement(getSubcolumn(properties_json,'experiment'),'String') AS experiment_id,
       variations[dynamicElement(getSubcolumn(properties_json,'variant'),'String')] AS variation_id
FROM exposures
WHERE throwIf(NOT mapContains(variations,dynamicElement(getSubcolumn(properties_json,'variant'),'String')),
              'configure an explicit mapping for every experiment variation')=0
ORDER BY occurred_at,event_id
SETTINGS enable_materialized_cte=1
