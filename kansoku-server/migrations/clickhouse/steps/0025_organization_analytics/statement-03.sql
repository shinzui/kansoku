

CREATE TABLE IF NOT EXISTS analytics.organization_properties
(account_id String,organization_id String,name String,
 value AggregateFunction(argMax,Tuple(String,String,Float64),Tuple(DateTime64(3,'UTC'),DateTime64(3,'UTC'),String)))
ENGINE=AggregatingMergeTree ORDER BY (account_id,organization_id,name);