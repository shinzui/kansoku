
CREATE OR REPLACE VIEW analytics.organization_traits AS
SELECT account_id,organization_id,name,selected.1 AS trait_type,selected.2 AS text_value,selected.3 AS number_value
FROM (SELECT account_id,organization_id,name,argMaxMerge(value) AS selected FROM analytics.organization_properties GROUP BY account_id,organization_id,name);