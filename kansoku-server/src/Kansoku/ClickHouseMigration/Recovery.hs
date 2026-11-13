-- | Deployment-neutral recovery manifests. Validation binds operator-retained
-- backup receipts; it does not perform backups or authenticate platform claims.
module Kansoku.ClickHouseMigration.Recovery
  ( RecoveryRequirement (..),
    AcceptedRecovery,
    validateRecoverySet,
    readRecoverySet,
    recoveryFileDigest,
    recoveryDocument,
    recoveryDigest,
    recoveryId,
    checkRecoveryCurrent,
    compiledPlanDigest,
    recoveryDocumentDigest,
    recoveryBytesDigest,
  )
where

import ClickHouseMigrate.Definition qualified as D
import ClickHouseMigrate.Plan qualified as P
import ClickHouseMigrate.Target qualified as T
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256 (..), hashWith)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither, (.:))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isControl, isHexDigit)
import Data.List (sort)
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import System.IO (IOMode (ReadMode), withBinaryFile)

data RecoveryRequirement = RecoveryRequirement
  { expectedTarget :: !Text,
    expectedServers :: ![Text],
    expectedLedger :: !Text,
    expectedSession :: !Text,
    expectedPredecessor :: !Integer,
    expectedPlanDigest :: !Text,
    expectedDrainDigest :: !Text,
    expectedPostgresDatabase :: !Text,
    expectedRetentionPolicy :: !A.Value,
    expectedCoordinatorState :: !A.Value,
    expectedDrainCompletedAt :: !UTCTime,
    expectedExclusionUntil :: !UTCTime
  }

data AcceptedRecovery = AcceptedRecovery
  { recoveryDocument :: !A.Value,
    recoveryDigest :: !Text,
    recoveryId :: !Text,
    validUntil :: !UTCTime
  }

instance Show AcceptedRecovery where
  show _ = "AcceptedRecovery <operator backup attestation>"

readRecoverySet :: UTCTime -> RecoveryRequirement -> FilePath -> IO (Either Text AcceptedRecovery)
readRecoverySet now expected path = withBinaryFile path ReadMode $ \handle ->
  validateRecoverySet now expected <$> BS.hGet handle 65537

validateRecoverySet :: UTCTime -> RecoveryRequirement -> BS.ByteString -> Either Text AcceptedRecovery
validateRecoverySet now expected bytes = do
  unless (BS.length bytes <= 65536) (Left "recovery set exceeds 64 KiB")
  value <- either (const (Left "invalid recovery-set JSON")) Right (A.eitherDecodeStrict' bytes)
  (ident, untilTime) <- either (const (Left "recovery set does not match complete pre-migration coverage, identities or interval")) Right (parseEither parse value)
  pure (AcceptedRecovery value (sha256 bytes) ident untilTime)
  where
    parse = A.withObject "recovery set" $ \o -> do
      exactKeys o ["schemaVersion", "id", "target", "servers", "ledger", "session", "predecessor", "planSha256", "drainSha256", "postgresDatabase", "retentionPolicy", "coordinatorState", "stableFrom", "stableUntil", "coordinatorSnapshotPhase", "backgroundChangesSettled", "operatorAttested", "snapshots"]
      version <- o .: "schemaVersion"
      unless (version == (1 :: Int)) (fail "unsupported schema")
      ident <- o .: "id"
      either (const (fail "invalid recovery-set ID")) (const (pure ())) (T.ledgerId ident)
      same o "target" (expectedTarget expected)
      servers <- o .: "servers"
      unless (not (null servers) && length servers <= 128 && sort servers == sort (expectedServers expected)) (fail "server inventory mismatch")
      same o "ledger" (expectedLedger expected)
      same o "session" (expectedSession expected)
      predecessor <- o .: "predecessor"
      unless (predecessor >= 0 && predecessor == expectedPredecessor expected) (fail "predecessor mismatch")
      same o "planSha256" (expectedPlanDigest expected)
      same o "drainSha256" (expectedDrainDigest expected)
      same o "postgresDatabase" (expectedPostgresDatabase expected)
      policy <- o .: "retentionPolicy"
      unless (policy /= A.Null && policy == expectedRetentionPolicy expected) (fail "policy mismatch")
      state <- o .: "coordinatorState"
      unless (state /= A.Null && state == expectedCoordinatorState expected) (fail "coordinator snapshot state mismatch")
      start <- o .: "stableFrom"
      end <- o .: "stableUntil"
      unless (expectedDrainCompletedAt expected <= start && start <= now && now < end && end <= expectedExclusionUntil expected) (fail "invalid stable window")
      same o "coordinatorSnapshotPhase" "fenced-before-native-entry"
      mapM_ (\key -> do flag <- o .: key; unless flag (fail "incomplete attestation")) ["backgroundChangesSettled", "operatorAttested"]
      snapshots <- o .: "snapshots"
      unless (length snapshots == 3) (fail "incomplete snapshots")
      coverage <- traverse (snapshot start end) snapshots
      unless (sort coverage == sort [("postgresql", expectedPostgresDatabase expected), ("clickhouse", "analytics"), ("clickhouse", "kansoku_migration_ledger")]) (fail "incomplete database coverage")
      pure (ident, end)
    snapshot :: UTCTime -> UTCTime -> A.Value -> Parser (Text, Text)
    snapshot start end = A.withObject "snapshot" $ \o -> do
      exactKeys o ["store", "database", "startedAt", "completedAt", "artifactReference", "artifactSha256", "verificationReference", "verificationSha256", "complete"]
      store <- o .: "store"
      database <- o .: "database"
      began <- o .: "startedAt"
      completed <- o .: "completedAt"
      unless (start <= began && began <= completed && completed <= now && completed <= end) (fail "snapshot outside stable interval")
      mapM_ (\key -> o .: key >>= \value -> unless (bounded value) (fail "invalid retained reference")) ["artifactReference", "verificationReference"]
      mapM_ (\key -> o .: key >>= \value -> unless (digest value) (fail "invalid retained digest")) ["artifactSha256", "verificationSha256"]
      complete <- o .: "complete"
      unless complete (fail "incomplete artifact")
      pure (store, database)

same :: A.Object -> Key.Key -> Text -> Parser ()
same object key expected = do
  actual <- object .: key
  unless (bounded actual && actual == expected) (fail "identity mismatch")

exactKeys :: A.Object -> [Text] -> Parser ()
exactKeys object keys = unless (sort (map Key.toText (KM.keys object)) == sort keys) (fail "unknown or missing fields")

bounded :: Text -> Bool
bounded value = not (Text.null (Text.strip value)) && Text.length value <= 1024 && not (Text.any isControl value)

digest :: Text -> Bool
digest value = Text.length value == 64 && Text.all isHexDigit value

sha256 :: BS.ByteString -> Text
sha256 bytes = Text.pack (show (hashWith SHA256 bytes :: Digest SHA256))

recoveryBytesDigest :: BS.ByteString -> Text
recoveryBytesDigest = sha256

checkRecoveryCurrent :: UTCTime -> AcceptedRecovery -> Either Text ()
checkRecoveryCurrent now recovery = unless (now < validUntil recovery) (Left "recovery-set exclusion window expired; fence retained")

-- Order and format are part of this application-owned fingerprint. Applied SQL
-- and toolkit checksums remain unchanged; the prefix separates this digest's use.
compiledPlanDigest :: P.MigrationPlan -> Text
compiledPlanDigest plan = sha256 ("kansoku-recovery-plan-v1\n" <> LBS.toStrict (A.encode definitions))
  where
    definitions =
      [ (D.componentNameText (D.migrationIdComponent (P.migrationId migration)), D.migrationNameText (D.migrationIdName (P.migrationId migration)), P.migrationChecksumHex (P.migrationChecksumFor P.ChecksumV2 migration))
      | migration <- NE.toList (P.inspectSchedule plan)
      ]

-- Existing accepted manifests may be reused by exact digest with fresh drain
-- evidence; their original stable interval is historical, not a new authority.
recoveryFileDigest :: FilePath -> IO (Either Text Text)
recoveryFileDigest path = withBinaryFile path ReadMode $ \handle -> do
  bytes <- BS.hGet handle 65537
  pure (if BS.length bytes <= 65536 then Right (sha256 bytes) else Left "recovery set exceeds 64 KiB")

recoveryDocumentDigest :: A.Value -> Text
recoveryDocumentDigest = sha256 . LBS.toStrict . A.encode
