-- | Pre-change backup acceptance at the retained administrative boundary.
module Kansoku.ClickHouseMigration.RecoveryGate (PreparedRecovery, context, prepare, auditEvidence, accept) where

import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Plan (MigrationPlan)
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target qualified as T
import Control.Monad (unless)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kansoku.Admin.Coordination qualified as C
import Kansoku.Admin.Store (field)
import Kansoku.ClickHouseMigration.Config qualified as Config
import Kansoku.ClickHouseMigration.Coordinator (identity)
import Kansoku.ClickHouseMigration.Recovery qualified as Recovery

data Acceptance = Snapshot !Recovery.AcceptedRecovery | Fresh !Text !A.Value

data PreparedRecovery = PreparedRecovery !(Maybe Acceptance) !A.Value

context :: Config.Config -> MigrationPlan -> IO A.Value
context config plan = do
  session <- identity config
  settings <- postgres config
  metadata <- C.recoveryContext settings session
  unless (metadata /= A.Null) (fail "Unknown recovery owner; begin or select the retained session")
  retained <- C.findRecoverySet settings session digest
  observed <- I.status I.Observe (Config.nativeConfig config False) plan
  let (pending, compatible) = case observed of
        Right (R.InspectionReport (R.HistoryReport _ _ (R.LedgerInitializedAt _) _ _ _ _ _) migrations issues) -> (any (\(R.MigrationSummary _ state _ _) -> state /= R.Applied && state /= R.Adopted) migrations, null issues)
        _ -> (False, False)
  pure (A.object ["target" A..= T.targetKeyText (Config.target config), "servers" A..= servers config, "ledger" A..= T.ledgerIdText (Config.ledger config), "session" A..= C.sessionId session, "predecessor" A..= field "entry" (field "session" metadata), "planSha256" A..= digest, "postgresDatabase" A..= field "postgresDatabase" metadata, "retentionPolicy" A..= field "retentionPolicy" metadata, "coordinatorState" A..= C.predecessorState (field "session" metadata), "fenced" A..= field "fenced" metadata, "retainedRecoverySet" A..= retained, "pendingSql" A..= pending, "compatible" A..= compatible])
  where
    digest = Recovery.compiledPlanDigest plan

-- Validate operator input before consuming a native entry. The subsequent lease
-- still checks exact identity and predecessor, so this cannot authorize a stale
-- snapshot after another cooperating administrator advanced the session.
prepare :: Config.Config -> MigrationPlan -> Bool -> Integer -> A.Value -> Maybe FilePath -> IO PreparedRecovery
prepare config plan repair predecessor audit supplied = do
  session <- identity config
  settings <- postgres config
  retained <- C.findRecoverySet settings session digest
  case (retained, supplied) of
    (row, Nothing) | row /= A.Null -> pure (reuse row)
    (row, Just path) | row /= A.Null -> do
      suppliedDigest <- Recovery.recoveryFileDigest path >>= checked
      if field "document_sha256" row == A.String suppliedDigest then pure (reuse row) else snapshot settings session path
    (_, Just path) -> snapshot settings session path
    _ -> do
      observed <- I.status I.Observe (Config.nativeConfig config False) plan
      case observed of
        Right (R.InspectionReport (R.HistoryReport _ _ presence _ _ _ _ _) migrations issues) -> case presence of
          R.LedgerMissing -> empty settings session
          R.LedgerUninitialized -> empty settings session
          _ | not repair && (not (null issues) || all applied migrations) -> pure (PreparedRecovery Nothing (A.object ["kind" A..= ("no-application-sql" :: Text), "planSha256" A..= digest]))
          _ -> fail "Complete --recovery-set FILE required before pending migration SQL; back up PostgreSQL, analytics and kansoku_migration_ledger in one fenced drained interval; fence retained"
        Left _ -> fail "Cannot establish pre-change native history for recovery acceptance; fence retained"
  where
    digest = Recovery.compiledPlanDigest plan
    applied (R.MigrationSummary _ state _ _) = state == R.Applied || state == R.Adopted
    proof kind ident sha = A.object ["kind" A..= kind, "id" A..= ident, "sha256" A..= sha, "planSha256" A..= digest]
    reuse row = PreparedRecovery Nothing (proof (field "kind" row) (field "recovery_id" row) (field "document_sha256" row))
    empty settings session = do
      Config.ensureFreshInitialization config
      ident <- C.newRecoveryId settings
      let document = A.object ["kind" A..= ("fresh-empty" :: Text), "session" A..= C.sessionId session, "target" A..= T.targetKeyText (Config.target config), "servers" A..= servers config, "ledger" A..= T.ledgerIdText (Config.ledger config), "predecessor" A..= predecessor, "planSha256" A..= digest, "drainSha256" A..= field "drainEvidenceSha256" audit]
      pure (PreparedRecovery (Just (Fresh ident document)) (proof (A.String "fresh-empty") (A.String ident) (A.String (Recovery.recoveryDocumentDigest document))))
    snapshot settings session path = do
      metadata <- C.recoveryContext settings session
      unless (field "fenced" metadata == A.Bool True) (fail "Recovery owner no longer owns the persistent fence")
      database <- decode (field "postgresDatabase" metadata)
      drainDigest <- decode (field "drainEvidenceSha256" audit)
      drained <- decode (field "drainedAt" (field "drainEvidence" audit))
      expires <- decode (field "expiresAt" (field "drainEvidence" audit))
      let expected = Recovery.RecoveryRequirement (T.targetKeyText (Config.target config)) (servers config) (T.ledgerIdText (Config.ledger config)) (C.sessionId session) predecessor digest drainDigest database (field "retentionPolicy" metadata) (field "predecessorState" audit) drained expires
      now <- getCurrentTime
      accepted <- Recovery.readRecoverySet now expected path >>= checked
      pure (PreparedRecovery (Just (Snapshot accepted)) (proof (A.String "snapshot") (A.String (Recovery.recoveryId accepted)) (A.String (Recovery.recoveryDigest accepted))))

auditEvidence :: PreparedRecovery -> A.Value -> A.Value
auditEvidence (PreparedRecovery _ proof) (A.Object audit) = A.Object (KM.insert "recoverySet" proof audit)
auditEvidence _ _ = error "Invalid validated administrative audit"

-- Persist acceptance only after owning the administrator lease and consuming its
-- predecessor marker, and before the toolkit can submit application SQL.
accept :: Config.Config -> MigrationPlan -> Integer -> PreparedRecovery -> IO ()
accept config plan predecessor (PreparedRecovery pending _) = do
  settings <- postgres config
  session <- identity config
  case pending of
    Nothing -> pure ()
    Just (Snapshot recovery) -> do
      now <- getCurrentTime
      checked (Recovery.checkRecoveryCurrent now recovery)
      C.retainRecoverySet settings session predecessor digest "snapshot" (Just (Recovery.recoveryId recovery)) (Recovery.recoveryDigest recovery) (Recovery.recoveryDocument recovery)
    Just (Fresh ident document) -> do
      Config.ensureFreshInitialization config
      C.retainRecoverySet settings session predecessor digest "fresh-empty" (Just ident) (Recovery.recoveryDocumentDigest document) document
  where
    digest = Recovery.compiledPlanDigest plan

postgres :: Config.Config -> IO Text
postgres = maybe (fail "PG_CONNECTION_STRING required for recovery acceptance") pure . Config.postgres

servers :: Config.Config -> [Text]
servers config = case Config.sessionTarget config of
  C.DirectTarget sid -> [sid]
  C.ReplicatedTarget _ ids -> ids

checked :: Either Text a -> IO a
checked = either (fail . Text.unpack) pure

decode :: (A.FromJSON a) => A.Value -> IO a
decode value = case A.fromJSON value of
  A.Success result -> pure result
  A.Error _ -> fail "Invalid retained recovery context"
