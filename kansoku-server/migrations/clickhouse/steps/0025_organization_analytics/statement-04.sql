
CREATE OR REPLACE VIEW analytics.organization_trait_events AS
WITH toFloat64OrNull(toString(getSubcolumn(properties_json,'seats'))) AS seat_number
SELECT account_id,organization_id,event_id,occurred_at,received_at,
trait.1 AS name,trait.2 AS trait_type,trait.3 AS text_value,trait.4 AS number_value
FROM analytics.events_canonical
ARRAY JOIN [('plan','string',ifNull(dynamicElement(getSubcolumn(properties_json,'plan'),'String'),''),toFloat64(0)),('industry','string',ifNull(dynamicElement(getSubcolumn(properties_json,'industry'),'String'),''),toFloat64(0)),('country','string',ifNull(dynamicElement(getSubcolumn(properties_json,'country'),'String'),''),toFloat64(0)),('seats','number','',ifNull(seat_number,toFloat64(0)))] AS trait
WHERE event_name='group' AND schema_version=2 AND organization_id!='' AND governed_traits_valid
AND (account_id,event_id) NOT IN (SELECT account_id,event_id FROM analytics.trait_event_erasures)
AND (NOT JSONHas(properties,'plan') OR dynamicType(getSubcolumn(properties_json,'plan'))='String')
AND (NOT JSONHas(properties,'industry') OR dynamicType(getSubcolumn(properties_json,'industry'))='String')
AND (NOT JSONHas(properties,'country') OR dynamicType(getSubcolumn(properties_json,'country'))='String')
AND (NOT JSONHas(properties,'seats') OR (dynamicType(getSubcolumn(properties_json,'seats')) IN ('Int64','UInt64','Float64') AND isFinite(seat_number) AND seat_number>=0 AND floor(seat_number)=seat_number))
AND JSONHas(properties,trait.1);