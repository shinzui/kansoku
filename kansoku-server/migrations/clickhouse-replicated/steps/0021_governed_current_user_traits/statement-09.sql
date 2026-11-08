

INSERT INTO analytics.user_properties
SELECT account_id,user_id,name,argMaxState(tuple(trait_type,text_value,number_value),tuple(occurred_at,received_at,event_id)) AS value
FROM (SELECT * FROM analytics.user_trait_events) WHERE event_name='identify' GROUP BY account_id,user_id,name;