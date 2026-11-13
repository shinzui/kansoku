-- | Explicit adoption of an operator-restored direct server. Native history is
-- observed through the public toolkit and never rewritten by this operation.
module Kansoku.ClickHouseMigration.Rebind (observe, rebind) where

import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Plan (MigrationPlan)
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target qualified as T
import Control.Monad (unless)
import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (UTCTime, getCurrentTime)
import Kansoku.Admin.Coordination qualified as C
import Kansoku.Admin.DrainEvidence qualified as Drain
import Kansoku.Admin.Store (field)
import Kansoku.ClickHouseMigration.Config qualified as Config
import Kansoku.ClickHouseMigration.Recovery qualified as Recovery
import System.Environment (lookupEnv)
import System.IO (IOMode (ReadMode), withBinaryFile)

observe :: Config.Config -> MigrationPlan -> IO A.Value
observe config plan = do
  result <- I.status I.Observe (Config.nativeConfig config False) plan
  case result of
    Right (R.InspectionReport history@(R.HistoryReport _ (Just server) (R.LedgerInitializedAt ledger) _ _ events _ unresolved) _ issues) -> do
      unless (ledger == Config.ledger config) (fail "Restored native ledger identity mismatch")
      -- Unresolved attempts are retained for explicit repair, never accepted as
      -- success. Definition changes and incomplete adoption remain refusals.
      unless (all unresolvedOnly issues) (fail "Restored native history is incompatible with the compiled plan")
      pure (A.object ["server" A..= T.serverIdText (T.identityServerId server), "version" A..= T.identityVersion server, "ledger" A..= T.ledgerIdText ledger, "ledgerSha256" A..= Recovery.recoveryDocumentDigest (A.String (Text.pack (show events))), "unresolved" A..= unresolved, "historyPosition" A..= Text.pack (show (position history))])
    _ -> fail "Cannot verify qualified restored native target and initialized ledger"
  where
    unresolvedOnly (R.UnresolvedAttempt _) = True
    unresolvedOnly _ = False
    position (R.HistoryReport _ _ _ p _ _ _ _) = p

rebind :: Config.Config -> MigrationPlan -> Text -> Text -> FilePath -> FilePath -> FilePath -> FilePath -> A.Value -> IO A.Value
rebind config plan oldServer newServer manifestPath originalDrainPath restorePath currentDrainPath audit = do
  unless (oldServer /= newServer) (fail "Rebinding requires different explicit old and new server UUIDs")
  case Config.sessionTarget config of
    C.DirectTarget configured -> unless (configured == newServer) (fail "Configured candidate UUID differs from explicit new server")
    _ -> fail "Rebuilt replicated inventory adoption requires a separately qualified procedure"
  ident <- maybe (fail "KANSOKU_CH_MIGRATION_SESSION required") pure (Config.session config)
  settings <- maybe (fail "PG_CONNECTION_STRING required") pure (Config.postgres config)
  (manifestBytes, manifest) <- readDocument manifestPath
  (originalBytes, originalDrain) <- readDocument originalDrainPath
  (restoreBytes, restore) <- readDocument restorePath
  let manifestDigest = Recovery.recoveryBytesDigest manifestBytes
      restoreDigest = Recovery.recoveryBytesDigest restoreBytes
  let old = C.SessionIdentity ident (T.targetKeyText (Config.target config)) (C.DirectTarget oldServer) (T.ledgerIdText (Config.ledger config))
      request = A.object ["oldServer" A..= oldServer, "newServer" A..= newServer, "manifestSha256" A..= manifestDigest, "restoreSha256" A..= restoreDigest, "audit" A..= audit]
  C.withRebindLease settings old newServer request $ \row -> do
    now <- getCurrentTime
    metadata <- C.recoveryContext settings old
    predecessor <- decode (field "entry" row)
    notBefore <- decode (field "last_entry_at" row)
    submitters <- lookupEnv "KANSOKU_CH_DRAIN_SUBMITTERS" >>= maybe (fail "Trusted drain submitter inventory required") (checked . either (const (Left "Invalid trusted drain inventory")) Right . A.eitherDecodeStrict' . Encoding.encodeUtf8 . Text.pack)
    let requirement servers = Drain.DrainRequirement (C.targetKey old) servers (Just (C.ledgerId old)) ["analytics", "kansoku_migration_ledger"] (Config.username config : submitters) [Config.username config] (Drain.MigrationSession ident predecessor) notBefore
    current <- Drain.readDrainEvidence now (requirement [newServer]) currentDrainPath >>= checked
    -- Revalidate the historical source proof at the end of capture, rather than
    -- extending its expired exclusion interval into present-day authority.
    captures <- decode (field "snapshots" manifest) :: IO [A.Value]
    completed <- traverse (decode . field "completedAt") captures :: IO [UTCTime]
    capturedAt <- case completed of [] -> fail "Recovery set has no captures"; x : xs -> pure (foldr max x xs)
    unless (capturedAt <= now) (fail "Recovery snapshot is in the future")
    original <- checked (Drain.validateDrainEvidence capturedAt (requirement [oldServer]) originalBytes)
    database <- decode (field "postgresDatabase" metadata)
    drainedAt <- decode (field "drainedAt" originalDrain)
    exclusionUntil <- decode (field "expiresAt" originalDrain)
    let expected = Recovery.RecoveryRequirement (C.targetKey old) [oldServer] (C.ledgerId old) ident predecessor (Recovery.compiledPlanDigest plan) (Drain.acceptedDigest original) database (field "retentionPolicy" metadata) (C.predecessorState row) drainedAt exclusionUntil
    accepted <- checked (Recovery.validateRecoverySet capturedAt expected manifestBytes)
    observed <- observe config plan
    inspected <- decode (field "inspectedAt" restore)
    expires <- decode (field "expiresAt" restore)
    unless (inspected <= now && inspected >= notBefore && now < expires && expires <= currentExpiry current) (fail "Restore verification is stale or outside current exclusion")
    let required = A.object ["schemaVersion" A..= (1 :: Int), "mode" A..= ("live-recovery" :: Text), "target" A..= C.targetKey old, "oldServer" A..= oldServer, "newServer" A..= newServer, "ledger" A..= C.ledgerId old, "session" A..= ident, "recoverySetId" A..= Recovery.recoveryId accepted, "recoverySetSha256" A..= manifestDigest, "ledgerSha256" A..= field "ledgerSha256" observed, "inspectedAt" A..= field "inspectedAt" restore, "expiresAt" A..= field "expiresAt" restore, "allStoresRestored" A..= True, "operatorAttested" A..= True]
    unless (restore == required) (fail "Live restore provenance does not match complete recovery set and observed history")
    finished <- getCurrentTime
    checked (Drain.checkDrainCurrent finished current)
    unless (finished < expires) (fail "Restore verification expired during observation")
    pure (A.object ["manifest" A..= Recovery.recoveryDocument accepted, "originalDrain" A..= Drain.acceptedDocument original, "currentDrain" A..= Drain.acceptedDocument current, "currentDrainSha256" A..= Drain.acceptedDigest current, "restoreVerification" A..= restore, "observation" A..= observed])
  where
    currentExpiry = either (const (error "validated drain expiry")) id . decodePure . field "expiresAt" . Drain.acceptedDocument

readDocument :: FilePath -> IO (BS.ByteString, A.Value)
readDocument path = withBinaryFile path ReadMode $ \handle -> do
  bytes <- BS.hGet handle 65537
  unless (BS.length bytes <= 65536) (fail "Recovery document exceeds 64 KiB")
  value <- checked (either (const (Left "Invalid recovery document JSON")) Right (A.eitherDecodeStrict' bytes))
  pure (bytes, value)

decodePure :: (A.FromJSON a) => A.Value -> Either Text a
decodePure value = case A.fromJSON value of A.Success x -> Right x; _ -> Left "Invalid recovery metadata"

decode :: (A.FromJSON a) => A.Value -> IO a
decode = checked . decodePure

checked :: Either Text a -> IO a
checked = either (fail . Text.unpack) pure
