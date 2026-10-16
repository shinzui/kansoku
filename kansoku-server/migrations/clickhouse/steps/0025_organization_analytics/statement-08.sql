

CREATE TABLE IF NOT EXISTS analytics.user_organizations
(account_id String,user_id String,
 organization_id AggregateFunction(argMax,String,Tuple(DateTime64(3,'UTC'),DateTime64(3,'UTC'),String)))
ENGINE=AggregatingMergeTree ORDER BY (account_id,user_id);