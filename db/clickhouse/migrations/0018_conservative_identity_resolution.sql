-- EP-32: writer-stopped identity evidence/index rebuild and conservative exact resolution.
-- Reapply after interruption with the writer still stopped. Canonical raw facts
-- are authoritative; max/unique state rebuilds never append incompatible history.
-- Length-prefixed components are lossless, including separators and UTF-8.
-- Persist this key so metrics read/hash one string instead of five key vectors.
ALTER TABLE analytics.events_raw ADD COLUMN IF NOT EXISTS identity_context_key String MATERIALIZED concat(toString(length(account_id)),':',account_id,toString(length(source_service)),':',source_service,toString(length(session_id)),':',session_id,toString(length(anonymous_id)),':',anonymous_id,toString(length(identifiers)),':',identifiers);
ALTER TABLE analytics.events_raw MATERIALIZE COLUMN identity_context_key SETTINGS mutations_sync=2;
CREATE OR REPLACE VIEW analytics.events_canonical
AS SELECT *,properties_json,identity_context_key FROM analytics.events_raw FINAL;

DROP TABLE IF EXISTS analytics.mv_identity_signal_users;
DROP TABLE IF EXISTS analytics.mv_identity_session_users;
DROP TABLE IF EXISTS analytics.mv_identity_signals;
DROP TABLE IF EXISTS analytics.identity_signals_rebuild;
CREATE TABLE analytics.identity_signals_rebuild
(
    account_id String, signal_kind LowCardinality(String), signal_value String,
    user_id String, observed_at DateTime64(3, 'UTC'), event_id String,
    received_at DateTime64(3, 'UTC'), source_service String, session_id String
)
ENGINE = ReplacingMergeTree
ORDER BY (account_id, signal_kind, signal_value, user_id, observed_at, event_id)
TTL toDateTime(observed_at) + INTERVAL 180 DAY + INTERVAL 1 SECOND DELETE WHERE signal_kind = 'fingerprint';

INSERT INTO analytics.identity_signals_rebuild
SELECT account_id, sig.1, sig.2, user_id, occurred_at, event_id, received_at, source_service, session_id
FROM analytics.events_canonical
ARRAY JOIN arrayDistinct(arrayFilter(kv -> kv.1 != '' AND kv.2 != '',
    arrayConcat([(if(event_name IN ('identify','identify_once','alias'), 'cookie', ''), anonymous_id)],
                JSONExtractKeysAndValues(identifiers, 'String')))) AS sig
WHERE user_id != '';
EXCHANGE TABLES analytics.identity_signals AND analytics.identity_signals_rebuild;
DROP TABLE analytics.identity_signals_rebuild;

CREATE MATERIALIZED VIEW analytics.mv_identity_signals TO analytics.identity_signals AS
SELECT account_id, sig.1 AS signal_kind, sig.2 AS signal_value, user_id,
       occurred_at AS observed_at, event_id, received_at, source_service, session_id
FROM analytics.events_raw
ARRAY JOIN arrayDistinct(arrayFilter(kv -> kv.1 != '' AND kv.2 != '',
    arrayConcat([(if(event_name IN ('identify','identify_once','alias'), 'cookie', ''), anonymous_id)],
                JSONExtractKeysAndValues(identifiers, 'String')))) AS sig
WHERE user_id != '';

-- Compact exact indexes retain one latest timestamp per observed signal/user,
-- and one per cookie/session/user. Max is replay-safe; evidence remains auditable.
DROP TABLE IF EXISTS analytics.mv_identity_signal_users;
DROP TABLE IF EXISTS analytics.mv_identity_session_users;
CREATE TABLE IF NOT EXISTS analytics.identity_signal_users
(
    account_id String, signal_kind LowCardinality(String), signal_value String, user_id String,
    observed_at SimpleAggregateFunction(max, DateTime64(3, 'UTC'))
)
ENGINE = AggregatingMergeTree ORDER BY (account_id, signal_kind, signal_value, user_id)
TTL toDateTime(observed_at) + INTERVAL 180 DAY + INTERVAL 1 SECOND DELETE WHERE signal_kind = 'fingerprint';
CREATE TABLE IF NOT EXISTS analytics.identity_session_users
(
    account_id String, source_service String, session_id String, signal_value String, user_id String,
    observed_at SimpleAggregateFunction(max, DateTime64(3, 'UTC'))
)
ENGINE = AggregatingMergeTree ORDER BY (account_id, source_service, session_id, signal_value, user_id);
DROP TABLE IF EXISTS analytics.identity_signal_users_rebuild;
DROP TABLE IF EXISTS analytics.identity_session_users_rebuild;
CREATE TABLE analytics.identity_signal_users_rebuild AS analytics.identity_signal_users;
CREATE TABLE analytics.identity_session_users_rebuild AS analytics.identity_session_users;
INSERT INTO analytics.identity_signal_users_rebuild
SELECT account_id, signal_kind, signal_value, user_id, max(observed_at)
FROM analytics.identity_signals FINAL GROUP BY account_id, signal_kind, signal_value, user_id;
INSERT INTO analytics.identity_session_users_rebuild
SELECT account_id, source_service, session_id, signal_value, user_id, max(observed_at)
FROM analytics.identity_signals FINAL WHERE signal_kind = 'cookie' AND session_id != ''
GROUP BY account_id, source_service, session_id, signal_value, user_id;
EXCHANGE TABLES analytics.identity_signal_users AND analytics.identity_signal_users_rebuild;
EXCHANGE TABLES analytics.identity_session_users AND analytics.identity_session_users_rebuild;
DROP TABLE analytics.identity_signal_users_rebuild;
DROP TABLE analytics.identity_session_users_rebuild;
CREATE MATERIALIZED VIEW analytics.mv_identity_signal_users TO analytics.identity_signal_users AS
SELECT account_id, signal_kind, signal_value, user_id, max(observed_at) AS observed_at
FROM analytics.identity_signals GROUP BY account_id, signal_kind, signal_value, user_id;
CREATE MATERIALIZED VIEW analytics.mv_identity_session_users TO analytics.identity_session_users AS
SELECT account_id, source_service, session_id, signal_value, user_id, max(observed_at) AS observed_at
FROM analytics.identity_signals WHERE signal_kind = 'cookie' AND session_id != ''
GROUP BY account_id, source_service, session_id, signal_value, user_id;

-- Identity depends on a context, not each individual event. Keep an exact
-- replay-safe per-day signal index so repeated session activity does not need
-- raw JSON expansion on every read. Raw candidates still bound returned facts.
DROP TABLE IF EXISTS analytics.mv_identity_context_signals;
CREATE TABLE IF NOT EXISTS analytics.identity_context_signals
(
    account_id String, day Date,
    context_key Tuple(String,String,String,String),
    signal_kind LowCardinality(String), signal_value String
)
ENGINE = ReplacingMergeTree ORDER BY (account_id,day,context_key,signal_kind,signal_value);
DROP TABLE IF EXISTS analytics.identity_context_signals_rebuild;
CREATE TABLE analytics.identity_context_signals_rebuild AS analytics.identity_context_signals;
INSERT INTO analytics.identity_context_signals_rebuild
SELECT account_id,toDate(occurred_at),tuple(source_service,session_id,anonymous_id,identifiers),sig.1,sig.2
FROM analytics.events_canonical
ARRAY JOIN arrayDistinct(arrayFilter(kv -> kv.2!='',
    arrayConcat([('cookie',anonymous_id)],JSONExtractKeysAndValues(identifiers,'String')))) AS sig
WHERE user_id='';
EXCHANGE TABLES analytics.identity_context_signals AND analytics.identity_context_signals_rebuild;
DROP TABLE analytics.identity_context_signals_rebuild;
CREATE MATERIALIZED VIEW analytics.mv_identity_context_signals TO analytics.identity_context_signals AS
SELECT account_id,toDate(occurred_at) AS day,tuple(source_service,session_id,anonymous_id,identifiers) AS context_key,
       sig.1 AS signal_kind,sig.2 AS signal_value
FROM analytics.events_raw
ARRAY JOIN arrayDistinct(arrayFilter(kv -> kv.2!='',
    arrayConcat([('cookie',anonymous_id)],JSONExtractKeysAndValues(identifiers,'String')))) AS sig
WHERE user_id='';

CREATE OR REPLACE VIEW analytics.identity_bindings AS
SELECT account_id, signal_kind, signal_value, user_id, observed_at,
       multiIf(signal_kind IN ('email_hmac','email_sha256'), 0.95,
               signal_kind = 'cookie', 0.90, signal_kind = 'device', 0.80,
               signal_kind = 'fingerprint', 0.50, 0.0) AS confidence
FROM analytics.identity_signals FINAL
WHERE signal_kind != 'fingerprint' OR observed_at >= now64(3) - INTERVAL 180 DAY;
CREATE OR REPLACE VIEW analytics.identity_conflicts AS
SELECT account_id, signal_kind, signal_value, arraySort(groupUniqArray(user_id)) AS user_ids,
       uniqExact(user_id) AS user_count, count() AS observation_count, max(observed_at) AS last_observed_at
FROM analytics.identity_bindings GROUP BY account_id, signal_kind, signal_value HAVING user_count > 1;

-- Parameterized candidates are bounded BEFORE mapped-signal expansion. Evidence
-- is indexed separately and is intentionally not bounded by the candidate dates.
-- all_accounts is an explicit administrative/public-SQL flag, never inferred
-- from an empty account ID. HTTP always passes zero.
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

DROP TABLE IF EXISTS analytics.mv_dau;
DROP TABLE IF EXISTS analytics.dau_rebuild;
CREATE TABLE analytics.dau_rebuild AS analytics.dau;
INSERT INTO analytics.dau_rebuild (account_id,day,users)
SELECT account_id, toDate(occurred_at) AS day, uniqCombinedState(if(user_id!='',concat('user:',user_id),concat('anonymous:',anonymous_id))) AS users
FROM analytics.events_canonical WHERE user_id != '' OR anonymous_id != ''
GROUP BY account_id, day;
EXCHANGE TABLES analytics.dau AND analytics.dau_rebuild;
DROP TABLE analytics.dau_rebuild;
CREATE MATERIALIZED VIEW analytics.mv_dau TO analytics.dau AS
SELECT account_id, toDate(occurred_at) AS day, uniqCombinedState(if(user_id!='',concat('user:',user_id),concat('anonymous:',anonymous_id))) AS users
FROM analytics.events_raw WHERE user_id != '' OR anonymous_id != ''
GROUP BY account_id, day;

DROP TABLE IF EXISTS analytics.mv_wau;
DROP TABLE IF EXISTS analytics.wau_rebuild;
CREATE TABLE analytics.wau_rebuild AS analytics.wau;
INSERT INTO analytics.wau_rebuild (account_id,week,users)
SELECT account_id, toMonday(occurred_at) AS week, uniqCombinedState(if(user_id!='',concat('user:',user_id),concat('anonymous:',anonymous_id))) AS users
FROM analytics.events_canonical WHERE user_id != '' OR anonymous_id != ''
GROUP BY account_id, week;
EXCHANGE TABLES analytics.wau AND analytics.wau_rebuild;
DROP TABLE analytics.wau_rebuild;
CREATE MATERIALIZED VIEW analytics.mv_wau TO analytics.wau AS
SELECT account_id, toMonday(occurred_at) AS week, uniqCombinedState(if(user_id!='',concat('user:',user_id),concat('anonymous:',anonymous_id))) AS users
FROM analytics.events_raw WHERE user_id != '' OR anonymous_id != ''
GROUP BY account_id, week;

DROP TABLE IF EXISTS analytics.mv_experiment_exposures;
DROP TABLE IF EXISTS analytics.experiment_exposures_rebuild;
CREATE TABLE analytics.experiment_exposures_rebuild AS analytics.experiment_exposures;
INSERT INTO analytics.experiment_exposures_rebuild (account_id,experiment,variant,day,users)
SELECT account_id, toDate(occurred_at) AS day, CAST(toString(getSubcolumn(properties_json, 'experiment')), 'String') AS experiment, CAST(toString(getSubcolumn(properties_json, 'variant')), 'String') AS variant, uniqCombinedState(if(user_id!='',concat('user:',user_id),concat('anonymous:',anonymous_id))) AS users
FROM analytics.events_canonical WHERE event_name = 'experiment_viewed' AND (user_id != '' OR anonymous_id != '') AND match(experiment, '^[a-z0-9_.:-]{1,128}$') AND match(variant, '^[a-z0-9_.:-]{1,128}$')
GROUP BY account_id, experiment, variant, day;
EXCHANGE TABLES analytics.experiment_exposures AND analytics.experiment_exposures_rebuild;
DROP TABLE analytics.experiment_exposures_rebuild;
CREATE MATERIALIZED VIEW analytics.mv_experiment_exposures TO analytics.experiment_exposures AS
SELECT account_id, toDate(occurred_at) AS day, CAST(toString(getSubcolumn(properties_json, 'experiment')), 'String') AS experiment, CAST(toString(getSubcolumn(properties_json, 'variant')), 'String') AS variant, uniqCombinedState(if(user_id!='',concat('user:',user_id),concat('anonymous:',anonymous_id))) AS users
FROM analytics.events_raw WHERE event_name = 'experiment_viewed' AND (user_id != '' OR anonymous_id != '') AND match(experiment, '^[a-z0-9_.:-]{1,128}$') AND match(variant, '^[a-z0-9_.:-]{1,128}$')
GROUP BY account_id, experiment, variant, day;

-- Exact context snapshots. The connection refresh deadline is the earliest
-- future fingerprint expiry in its evidence. Parameters defer temporary binding.
CREATE OR REPLACE VIEW analytics.identity_context_resolution AS
WITH
    (a,k,v) -> arrayDistinct(arrayMap(p -> p.1,
        arrayFilter(p -> k!='fingerprint' OR p.2>=now64(3)-INTERVAL 180 DAY,
                    joinGet('kansoku_signal_cache','observations',a,k,v)))) AS global_users,
    (a,svc,sid,v) -> joinGet('kansoku_session_cache','users',a,svc,sid,v) AS session_users,
    k -> multiIf(k IN ('email_hmac','email_sha256'),0.95,k='cookie',0.90,k='device',0.80,k='fingerprint',0.50,0.0) AS confidence,
    (a,svc,sid,k,v) -> if(k='cookie' AND sid!='' AND notEmpty(session_users(a,svc,sid,v)),
                         session_users(a,svc,sid,v),global_users(a,k,v)) AS bound_users
SELECT * EXCEPT(targets,best_confidence,winners),if(length(winners)=1,winners[1],'') AS stitched_user
FROM
(
    SELECT *,arrayMax(arrayMap(h -> h.2,targets)) AS best_confidence,
           arrayDistinct(arrayMap(h -> h.1[1],arrayFilter(h -> h.2=best_confidence,targets))) AS winners
    FROM
    (
        SELECT *,arrayFilter(h -> length(h.1)=1 AND h.2>=0.50,
            arrayMap(sig -> tuple(bound_users(account_id,source_service,session_id,sig.1,sig.2),confidence(sig.1)),
                arrayDistinct(arrayFilter(sig -> sig.2!='',arrayConcat([('cookie',anonymous_id)],
                    JSONExtractKeysAndValues(identifiers,'String')))))) AS targets
        FROM
        (
            SELECT DISTINCT account_id,context_key.1 AS source_service,context_key.2 AS session_id,
                            context_key.3 AS anonymous_id,context_key.4 AS identifiers
            FROM analytics.identity_context_signals FINAL
            WHERE ({scope_all_accounts:UInt8}=1 OR account_id={scope_account:String})
              AND day>={scope_from:Date} AND day<{scope_to:Date}

        )
    )
);

-- HTTP-only relation. The physical query connection refreshes this exact
-- snapshot on index revisions and before its earliest fingerprint expiry.
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
