

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
