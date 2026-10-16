-- EP-33: additive private enrichment; no producer-chosen categorical columns.
-- Existing development facts retain unknown/version-zero enrichment. Reclassification
-- is an explicit rebuild operation, never an implicit change to accepted events.
ALTER TABLE analytics.events_raw
    ADD COLUMN IF NOT EXISTS browser_family LowCardinality(String) DEFAULT 'unknown',
    ADD COLUMN IF NOT EXISTS os_family LowCardinality(String) DEFAULT 'unknown',
    ADD COLUMN IF NOT EXISTS device_class LowCardinality(String) DEFAULT 'unknown',
    ADD COLUMN IF NOT EXISTS is_bot Bool DEFAULT false,
    ADD COLUMN IF NOT EXISTS channel LowCardinality(String) DEFAULT 'unknown',
    ADD COLUMN IF NOT EXISTS country_code LowCardinality(String) DEFAULT '',
    ADD COLUMN IF NOT EXISTS enrichment_version UInt16 DEFAULT 0,
    ADD COLUMN IF NOT EXISTS context_json JSON(max_dynamic_paths=256)
        MATERIALIZED CAST(if(isValidJSON(context),context,'{}') AS JSON(max_dynamic_paths=256));

CREATE OR REPLACE VIEW analytics.events_canonical
AS SELECT *,properties_json,identity_context_key,context_json FROM analytics.events_raw FINAL;

-- Refresh view headers after adding raw columns; keep the public seven-column shape.
CREATE OR REPLACE VIEW analytics.events_resolved_internal AS
WITH
candidates AS
(
    SELECT * FROM analytics.events_canonical
    WHERE ({scope_all_accounts:UInt8} = 1 OR account_id = {scope_account:String})
      AND occurred_at >= {scope_from:DateTime64(3, 'UTC')}
      AND occurred_at < {scope_to:DateTime64(3, 'UTC')}
),
candidate_signals AS MATERIALIZED
(
    SELECT DISTINCT account_id, context_key, context_key.1 AS source_service, context_key.2 AS session_id,
           signal_kind, signal_value
    FROM analytics.identity_context_signals FINAL
    WHERE ({scope_all_accounts:UInt8} = 1 OR account_id = {scope_account:String})
      AND day >= toDate({scope_from:DateTime64(3, 'UTC')})
      AND toDateTime64(day,3,'UTC') < {scope_to:DateTime64(3, 'UTC')}
),
bindings AS
(
    SELECT account_id, signal_kind, signal_value, uniqExact(user_id) AS users, min(user_id) AS unique_user,
           multiIf(signal_kind IN ('email_hmac','email_sha256'), 0.95,
                   signal_kind = 'cookie', 0.90, signal_kind = 'device', 0.80,
                   signal_kind = 'fingerprint', 0.50, 0.0) AS confidence
    FROM analytics.identity_signal_users
    WHERE ({scope_all_accounts:UInt8} = 1 OR account_id = {scope_account:String})
      AND (account_id,signal_kind,signal_value) IN (SELECT account_id,signal_kind,signal_value FROM candidate_signals)
      AND (signal_kind != 'fingerprint' OR observed_at >= now64(3) - INTERVAL 180 DAY)
    GROUP BY account_id, signal_kind, signal_value
),
session_users AS
(
    SELECT account_id, source_service, session_id, signal_value, uniqExact(user_id) AS users,
           min(user_id) AS unique_user
    FROM analytics.identity_session_users
    WHERE ({scope_all_accounts:UInt8} = 1 OR account_id = {scope_account:String})
      AND (account_id,source_service,session_id,signal_value) IN
        (SELECT account_id,source_service,session_id,signal_value FROM candidate_signals WHERE signal_kind='cookie' AND session_id!='')
    GROUP BY account_id, source_service, session_id, signal_value
),
matches AS
(
    SELECT m.account_id AS account_id, m.context_key AS context_key,
           if(m.signal_kind = 'cookie' AND s.users > 0, s.unique_user, b.unique_user) AS candidate_user,
           b.confidence AS confidence
    FROM candidate_signals AS m
    LEFT JOIN bindings AS b ON b.account_id=m.account_id AND b.signal_kind=m.signal_kind AND b.signal_value=m.signal_value
    LEFT JOIN session_users AS s ON m.signal_kind='cookie' AND s.account_id=m.account_id
      AND s.source_service=m.source_service AND s.session_id=m.session_id AND s.signal_value=m.signal_value
    WHERE if(m.signal_kind='cookie' AND s.users > 0, s.users, b.users) = 1 AND b.confidence >= 0.50
),
best AS
(
    SELECT account_id, context_key, groupArray(tuple(candidate_user,confidence)) AS hits,
           arrayMax(arrayMap(h -> h.2,hits)) AS winning_confidence,
           arrayDistinct(arrayMap(h -> h.1,arrayFilter(h -> h.2=winning_confidence,hits))) AS winners,
           if(length(winners)=1,winners[1],'') AS stitched_user
    FROM matches GROUP BY account_id, context_key
),
subjects AS
(
    SELECT e.* EXCEPT(account_id), e.account_id AS account_id,
           multiIf(e.user_id!='','user',m.stitched_user!='','user',e.anonymous_id!='','anonymous','') AS subject_kind,
           multiIf(e.user_id!='',e.user_id,m.stitched_user!='',m.stitched_user,e.anonymous_id) AS subject_id
    FROM candidates AS e
    LEFT JOIN best AS m ON m.account_id=e.account_id AND m.context_key=tuple(e.source_service,e.session_id,e.anonymous_id,e.identifiers)
)
SELECT *, if(subject_kind='', '', concat(subject_kind, ':', subject_id)) AS canonical_user
FROM subjects
SETTINGS enable_materialized_cte=1;

CREATE OR REPLACE VIEW analytics.events_resolved_v3 AS
SELECT event_id,event_name,occurred_at,url,account_id,canonical_user,properties_json
FROM analytics.events_resolved_internal(scope_all_accounts=1,scope_account='',
    scope_from=toDateTime64('1970-01-01 00:00:00',3,'UTC'),scope_to=toDateTime64('2100-01-01 00:00:00',3,'UTC'));
CREATE OR REPLACE VIEW analytics.events_resolved AS SELECT * FROM analytics.events_resolved_v3;


CREATE OR REPLACE VIEW analytics.events_resolved_http AS
SELECT *,canonical_user,
       if(startsWith(canonical_user,'user:'),'user',if(startsWith(canonical_user,'anonymous:'),'anonymous','')) AS subject_kind,
       substring(canonical_user,length(subject_kind)+2) AS subject_id
FROM analytics.events_canonical
ARRAY JOIN [if(user_id!='',concat('user:',user_id),
    joinGet('kansoku_context_cache','canonical_user',identity_context_key))] AS canonical_user
WHERE ({scope_all_accounts:UInt8}=1 OR account_id={scope_account:String})
  AND throwIf(joinGet('kansoku_identity_clock','deadline',toUInt8(0))<=toUnixTimestamp64Milli(now64(3)), 'identity snapshot expired')=0
  AND occurred_at>={scope_from:DateTime64(3,'UTC')} AND occurred_at<{scope_to:DateTime64(3,'UTC')};
