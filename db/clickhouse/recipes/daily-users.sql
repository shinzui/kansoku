SELECT toDate(occurred_at) AS day, toFloat64(uniqExact(canonical_user)) AS value
FROM analytics.events_analytics_v1(account={account:String},
    from_time={from_time:DateTime64(3,'UTC')}, to_time={to_time:DateTime64(3,'UTC')})
WHERE source_service={source_service:String} AND canonical_user!='' AND NOT is_bot
  AND event_name NOT IN ('identify','identify_once','alias','group')
GROUP BY day ORDER BY day
