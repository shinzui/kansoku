
CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_user_organizations TO analytics.user_organizations AS
SELECT account_id,user_id,argMaxState(r.organization_id,tuple(occurred_at,received_at,event_id)) AS organization_id
FROM analytics.events_raw AS r
WHERE event_name='group' AND r.organization_id!='' AND user_id!=''
AND (account_id,event_id) NOT IN (SELECT account_id,event_id FROM analytics.trait_event_erasures)
GROUP BY account_id,user_id;