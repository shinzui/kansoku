

CREATE TABLE IF NOT EXISTS analytics.user_properties_once
(account_id String,user_id String,name String,
 value AggregateFunction(argMin,Tuple(String,String,Float64),Tuple(DateTime64(3,'UTC'),DateTime64(3,'UTC'),String)))
ENGINE=AggregatingMergeTree ORDER BY (account_id,user_id,name);