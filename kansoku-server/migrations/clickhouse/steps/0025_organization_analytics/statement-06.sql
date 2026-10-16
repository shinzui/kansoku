
INSERT INTO analytics.organization_properties
SELECT account_id,organization_id,name,argMaxState(tuple(trait_type,text_value,number_value),tuple(occurred_at,received_at,event_id)) AS value
FROM (SELECT * FROM analytics.organization_trait_events) GROUP BY account_id,organization_id,name;