

CREATE OR REPLACE VIEW analytics.user_traits AS
SELECT account_id,user_id,name,selected.1 AS trait_type,selected.2 AS text_value,selected.3 AS number_value
FROM (
  SELECT account_id,user_id,name,argMax(candidate,priority) AS selected
  FROM (
    SELECT account_id,user_id,name,argMaxMerge(value) AS candidate,toUInt8(1) AS priority
    FROM analytics.user_properties GROUP BY account_id,user_id,name
    UNION ALL
    SELECT account_id,user_id,name,argMinMerge(value) AS candidate,toUInt8(0) AS priority
    FROM analytics.user_properties_once GROUP BY account_id,user_id,name
  ) GROUP BY account_id,user_id,name
);
