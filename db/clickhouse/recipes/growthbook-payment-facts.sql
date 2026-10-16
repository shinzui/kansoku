SELECT canonical_user AS user_id,
       occurred_at AS timestamp,
       if(dynamicType(getSubcolumn(properties_json,'amount')) IN ('Int64','UInt64','Float64') AND isFinite(toFloat64OrNull(toString(getSubcolumn(properties_json,'amount')))),toFloat64OrNull(toString(getSubcolumn(properties_json,'amount'))),CAST(NULL,'Nullable(Float64)')) AS amount
FROM analytics.events_analytics_v1(account={account:String},
    from_time={from_time:DateTime64(3,'UTC')}, to_time={to_time:DateTime64(3,'UTC')})
WHERE source_service={source_service:String} AND canonical_user!='' AND event_name='payment_completed' AND amount IS NOT NULL
ORDER BY occurred_at,event_id
