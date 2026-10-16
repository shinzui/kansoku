-- Sequential count, two steps, no exclusions/grouping. Process completion before
-- updating the latest start, so one event never supplies both repeated steps.
WITH timelines AS
(
    SELECT canonical_user,
           arraySort(groupArray(tuple(toUnixTimestamp64Milli(occurred_at),event_id,event_name))) AS timeline
    FROM analytics.events_analytics_v1(account={account:String},
        from_time={from_time:DateTime64(3,'UTC')}, to_time={to_time:DateTime64(3,'UTC')})
    WHERE source_service={source_service:String} AND canonical_user!=''
    GROUP BY canonical_user
), levels AS
(
    SELECT arrayFold((state,event)->tuple(
        if(event.3={first_step:String},event.1,state.1),
        state.2 OR event.3={first_step:String},
        state.3 OR (event.3={second_step:String} AND state.1>=0
                    AND event.1-state.1<=toInt64({window_seconds:UInt32})*1000)),
        timeline,tuple(toInt64(-1),toUInt8(0),toUInt8(0))) AS progress
    FROM timelines
)
SELECT item.1 AS step,toFloat64(item.2) AS value
FROM (SELECT countIf(progress.2) AS started,countIf(progress.3) AS completed FROM levels)
ARRAY JOIN [tuple(toUInt8(1),started),tuple(toUInt8(2),completed)] AS item
ORDER BY step
