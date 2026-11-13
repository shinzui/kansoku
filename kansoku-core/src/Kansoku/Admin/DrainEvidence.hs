-- | Portable operator attestations. Validation establishes binding and coverage,
-- not that a deployment actually performed the retained external procedure.
module Kansoku.Admin.DrainEvidence
  ( DrainOwner (..),
    DrainRequirement (..),
    AcceptedDrain,
    validateDrainEvidence,
    readDrainEvidence,
    acceptedDocument,
    acceptedDigest,
    checkDrainCurrent,
  )
where

import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256 (..), hashWith)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither, (.:))
import Data.ByteString qualified as BS
import Data.Char (isControl, isHexDigit)
import Data.List (find, isSuffixOf, nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, diffUTCTime)
import System.IO (IOMode (ReadMode), withBinaryFile)

-- | The counter is the persisted predecessor or the next prepared job attempt.
data DrainOwner = MigrationSession !Text !Integer | DataJob !Text !Integer
  deriving (Eq)

-- | Trusted expectations come from retained coordinator state and deployment
-- configuration, never from the supplied document. Include every writable user
-- and external schedule principal, including the migrator's predecessor work.
data DrainRequirement = DrainRequirement
  { requiredTarget :: !Text,
    requiredServers :: ![Text],
    requiredLedger :: !(Maybe Text),
    requiredDatabases :: ![Text],
    requiredSubmitters :: ![Text],
    requiredAvailablePrincipals :: ![Text],
    requiredOwner :: !DrainOwner,
    requiredNotBefore :: !UTCTime
  }

-- No public constructor: consumers can retain only validated documents.
data AcceptedDrain = AcceptedDrain {acceptedDocument :: A.Value, acceptedDigest :: Text, expiresAt :: UTCTime}

instance Show AcceptedDrain where
  show _ = "AcceptedDrain <operator attestation>"

-- | Read at most one byte beyond the limit, including for non-regular files.
readDrainEvidence :: UTCTime -> DrainRequirement -> FilePath -> IO (Either Text AcceptedDrain)
readDrainEvidence now expected path = withBinaryFile path ReadMode $ \handle ->
  validateDrainEvidence now expected <$> BS.hGet handle 65537

-- | At most 64 KiB. Read files with a bounded read before calling this function.
-- Errors deliberately exclude all untrusted document content.
validateDrainEvidence :: UTCTime -> DrainRequirement -> BS.ByteString -> Either Text AcceptedDrain
validateDrainEvidence now expected bytes = do
  check (BS.length bytes <= 65536) "drain evidence exceeds 64 KiB"
  value <- either (const (Left "invalid drain evidence JSON")) Right (A.eitherDecodeStrict' bytes)
  expiry <- either (Left . validationFailure) Right (parseEither parse value)
  pure (AcceptedDrain value (Text.pack (show (hashWith SHA256 bytes :: Digest SHA256))) expiry)
  where
    parse = A.withObject "drain evidence" $ \o -> do
      let keys = ["schemaVersion", "target", "servers", "ledger", "databases", "submitters", "availablePrincipals", "owner", "exclusionStartedAt", "drainedAt", "expiresAt", "procedureReference", "procedureSha256", "submittersBlocked", "schedulesPaused", "backgroundChangesSettled", "operatorAttested"]
      unless (sort (map Key.toText (KM.keys o)) == sort keys) (fail "unexpected fields")
      version <- o .: "schemaVersion"
      unless (version == (1 :: Int)) (fail "unsupported schema")
      target <- o .: "target"
      unless (validText target && target == requiredTarget expected) (fail "target mismatch")
      servers <- o .: "servers"
      exact "server inventory" servers (requiredServers expected)
      ledger <- o .: "ledger"
      unless (ledger == requiredLedger expected) (fail "ledger mismatch")
      databases <- o .: "databases"
      exact "database coverage" databases (requiredDatabases expected)
      submitters <- o .: "submitters"
      covers "submitter coverage" submitters (requiredSubmitters expected)
      available <- o .: "availablePrincipals"
      covers "available principal coverage" available (requiredAvailablePrincipals expected)
      -- An empty trusted inventory must never turn universal coverage vacuous.
      unless (not (null (requiredSubmitters expected)) && not (null (requiredAvailablePrincipals expected))) (fail "missing trusted principals")
      owner <- o .: "owner"
      unless (owner == ownerValue (requiredOwner expected) && validOwner (requiredOwner expected)) (fail "owner mismatch")
      started <- o .: "exclusionStartedAt"
      drained <- o .: "drainedAt"
      expires <- o .: "expiresAt"
      unless (requiredNotBefore expected <= drained && started <= drained && drained <= now && now < expires && diffUTCTime expires started <= 86400) (fail "stale exclusion interval")
      reference <- o .: "procedureReference"
      digest <- o .: "procedureSha256"
      unless (validText reference && Text.length digest == 64 && Text.all isHexDigit digest) (fail "invalid retained proof")
      mapM_ (\key -> do attested <- o .: key; unless attested (fail "incomplete attestation")) ["submittersBlocked", "schedulesPaused", "backgroundChangesSettled", "operatorAttested"]
      pure expires
    exact label actual required = do
      inventory actual
      unless (not (null required) && sort actual == sort required) (fail (label <> " mismatch"))
    covers label actual required = do
      inventory actual
      unless (all (`elem` actual) required) (fail ("incomplete " <> label))
    inventory values = unless (not (null values) && length values <= 128 && length (nub values) == length values && all validText values) (fail "invalid inventory")
    check True _ = Right ()
    check False message = Left message

validText :: Text -> Bool
validText value = not (Text.null (Text.strip value)) && Text.length value <= 1024 && not (Text.any isControl value)

validOwner :: DrainOwner -> Bool
validOwner (MigrationSession ident counter) = validText ident && counter >= 0
validOwner (DataJob ident counter) = validText ident && counter >= 1

ownerValue :: DrainOwner -> A.Value
ownerValue owner = case owner of
  MigrationSession ident counter -> A.object ["kind" A..= ("migration-session" :: Text), "id" A..= ident, "predecessor" A..= counter]
  DataJob ident counter -> A.object ["kind" A..= ("data-job" :: Text), "id" A..= ident, "attempt" A..= counter]

-- | Recheck after waiting for a lease or connection, immediately before native
-- use. Callers retain the accepted value rather than reopening a mutable file.
checkDrainCurrent :: UTCTime -> AcceptedDrain -> Either Text ()
checkDrainCurrent now evidence
  | now < expiresAt evidence = Right ()
  | otherwise = Left "drain evidence expired while waiting for exclusion; fence retained"

-- Preserve useful fixed refusal reasons without rendering parser diagnostics,
-- which may contain untrusted timestamp strings or other input data.
validationFailure :: String -> Text
validationFailure message = maybe "invalid drain evidence fields" Text.pack (find (`isSuffixOf` message) reasons)
  where
    reasons = ["unexpected fields", "unsupported schema", "target mismatch", "server inventory mismatch", "ledger mismatch", "database coverage mismatch", "incomplete submitter coverage", "incomplete available principal coverage", "missing trusted principals", "owner mismatch", "stale exclusion interval", "invalid retained proof", "incomplete attestation", "invalid inventory"]
