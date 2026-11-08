

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