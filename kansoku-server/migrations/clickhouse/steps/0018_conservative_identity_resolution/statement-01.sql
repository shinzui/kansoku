-- EP-32: writer-stopped identity evidence/index rebuild and conservative exact resolution.
-- Reapply after interruption with the writer still stopped. Canonical raw facts
-- are authoritative; max/unique state rebuilds never append incompatible history.
-- Length-prefixed components are lossless, including separators and UTF-8.
-- Persist this key so metrics read/hash one string instead of five key vectors.
ALTER TABLE analytics.events_raw ADD COLUMN IF NOT EXISTS identity_context_key String MATERIALIZED concat(toString(length(account_id)),':',account_id,toString(length(source_service)),':',source_service,toString(length(session_id)),':',session_id,toString(length(anonymous_id)),':',anonymous_id,toString(length(identifiers)),':',identifiers);