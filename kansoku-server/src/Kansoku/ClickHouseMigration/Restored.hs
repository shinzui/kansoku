-- | Restored-copy inspection has its own explicit connection/namespace boundary.
-- It neither loads the live mutation configuration nor contacts PostgreSQL.
module Kansoku.ClickHouseMigration.Restored (Options (..), inspect, expectations) where

import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Plan (MigrationPlan)
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target qualified as T
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Kansoku.Admin.Store (field)
import Kansoku.ClickHouseMigration.Recovery (compiledPlanDigest, recoveryBytesDigest)
import Kansoku.ClickHouseMigration.Schema qualified as Schema
import Kansoku.ClickHouseMigration.SchemaExpectation qualified as Expected
import Network.HTTP.Client qualified as H
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Network.HTTP.Types.URI (renderQuery)
import System.Environment (lookupEnv)
import System.IO (IOMode (ReadMode), withBinaryFile)

data Options = Options
  { endpoint :: !Text,
    server :: !Text,
    originalTarget :: !Text,
    originalLedger :: !Text,
    applicationDatabase :: !Text,
    ledgerDatabase :: !Text,
    expectedPlan :: !Text,
    expectedDefiner :: !Text,
    expectedPolicy :: !(Maybe FilePath)
  }

-- Offline discovery is checked against the actual compiled release, so an old
-- artifact cannot silently become the expectation for a newly appended plan.
expectations :: MigrationPlan -> IO A.Value
expectations plan = do
  either (fail . Text.unpack) pure (Expected.checkPlan plan)
  pure (A.object ["schemaVersion" A..= (1 :: Int), "planSha256" A..= compiledPlanDigest plan, "expectationSha256" A..= Expected.digest, "serverArtifact" A..= field "serverArtifact" Expected.document, "serverVersion" A..= field "serverVersion" Expected.document])

inspect :: Options -> MigrationPlan -> Maybe FilePath -> IO (A.Value, Bool)
inspect options plan recoveryFile = do
  either (fail . Text.unpack) pure (Expected.checkPlan plan)
  application <- checked (T.ledgerNamespace (applicationDatabase options))
  namespace <- checked (T.ledgerNamespace (ledgerDatabase options))
  unless (application /= namespace && all (`notElem` ["analytics", "kansoku_migration_ledger"]) [applicationDatabase options, ledgerDatabase options]) (fail "Explicit distinct scratch database names required; live names are refused")
  unless (expectedPlan options == compiledPlanDigest plan) (fail "Restored inspection expected compiled-plan digest mismatch")
  key <- checked (T.targetKey (originalTarget options))
  sid <- checked (T.serverId (server options))
  lid <- checked (T.ledgerId (originalLedger options))
  url <- checked (T.directEndpoint (endpoint options))
  user <- required "KANSOKU_CH_RESTORE_USER"
  secret <- required "KANSOKU_CH_RESTORE_PASSWORD"
  credentials <- checked (T.basicCredentials user secret)
  unless (not (Text.null (expectedDefiner options)) && Text.length (expectedDefiner options) <= 128 && not (Text.any (`elem` ['\r', '\n', '\0']) (expectedDefiner options))) (fail "Explicit bounded expected definer required")
  let config = T.targetConfig key url sid namespace (T.ExistingLedger lid) credentials T.defaultHttpLimits
  observation <- maybe (fail "Invalid restored inspection bounds") pure (I.boundedObservation 10000 1048576)
  observed <- I.status observation config plan
  let (compatible, current, unresolved) = case observed of
        Right (R.InspectionReport (R.HistoryReport _ _ (R.LedgerInitializedAt actual) _ _ _ _ pending) migrations issues) -> (actual == lid && null issues, actual == lid && null issues && not pending && all applied migrations, pending)
        _ -> (False, False, True)
  (schema, matched) <- case (expectedPolicy options, recoveryFile) of
    (Just _, Just _) -> fail "Supply expected policy or recovery set, not both"
    (Nothing, Nothing) -> pure (A.object ["status" A..= ("incomplete" :: Text), "reason" A..= ("Explicit expected retention policy or recovery set required" :: Text)], False)
    _ | not compatible -> pure (A.object ["status" A..= ("incomplete" :: Text), "reason" A..= ("Native ledger inspection failed" :: Text)], False)
    (source, backup) -> do
      let path = maybe (maybe (error "missing policy source") id backup) id source
      (policyBytes, document) <- readPolicy path
      policy <- case source of
        Just _ -> pure document
        Nothing -> do
          unless (field "schemaVersion" document == A.Number 1 && field "target" document == A.String (originalTarget options) && field "ledger" document == A.String (originalLedger options) && field "planSha256" document == A.String (compiledPlanDigest plan)) (fail "Recovery-set policy expectations have foreign identities or plan")
          pure (field "retentionPolicy" document)
      (revision, cutoff) <- either (fail . Text.unpack) pure (Schema.policyExpectation policy)
      bracket (H.newManager (H.managerSetProxy H.noProxy tlsManagerSettings {H.managerIdleConnectionCount = 0, H.managerRetryableException = const False})) H.closeManager $ \manager -> do
        let fetch = fetchRows manager url user secret (server options)
            database = applicationDatabase options
            dbLiteral = sqlLiteral database
            dbIdentifier = "`" <> database <> "`"
        databases <- fetch ("SELECT engine FROM system.databases WHERE name=" <> dbLiteral)
        engine <- case databases of [row] -> pure (field "engine" row); _ -> fail "Scratch database metadata missing or incomplete"
        tables <- fetch ("SELECT name,engine,engine_full,create_table_query,partition_key,sorting_key,primary_key,sampling_key FROM system.tables WHERE database=" <> dbLiteral <> " ORDER BY name")
        columns <- fetch ("SELECT table,name,type,position,default_kind,default_expression,compression_codec FROM system.columns WHERE database=" <> dbLiteral <> " ORDER BY table,position")
        principals <- fetch ("SELECT name FROM system.users WHERE name=" <> sqlLiteral (expectedDefiner options))
        policies <- fetch ("SELECT toString(max(revision)) AS observed_revision,arrayMap(x -> toString(x),groupUniqArrayIf(toUnixTimestamp64Milli(cutoff),revision=(SELECT max(revision) FROM " <> dbIdentifier <> ".retention_policy))) AS cutoffs FROM " <> dbIdentifier <> ".retention_policy")
        let expectedRelation = A.object ["observed_revision" A..= Text.pack (show revision), "cutoffs" A..= [Text.pack (show (maybe 0 id cutoff))]]
            policyMismatch = ["retention policy relation" | policies /= [expectedRelation]]
            definerMismatch = ["expected view definer is unavailable" | principals /= [A.object ["name" A..= expectedDefiner options]]]
        case Schema.compareSnapshot database (expectedDefiner options) policy engine tables columns of
          Left reason -> pure (A.object ["status" A..= ("unsupported" :: Text), "reason" A..= reason], False)
          Right differences -> do
            let allDifferences = differences <> policyMismatch <> definerMismatch
                equal = null allDifferences
            pure (A.object ["status" A..= (if equal then "matching" else "mismatch" :: Text), "matches" A..= equal, "mismatches" A..= allDifferences, "expectedPolicySha256" A..= recoveryBytesDigest policyBytes], equal)
  pure (A.object ["mode" A..= ("scratch-inspection" :: Text), "endpoint" A..= endpoint options, "server" A..= server options, "originalTarget" A..= originalTarget options, "originalLedger" A..= originalLedger options, "applicationDatabase" A..= applicationDatabase options, "ledgerDatabase" A..= ledgerDatabase options, "planSha256" A..= compiledPlanDigest plan, "expectationSha256" A..= Expected.digest, "ledger" A..= A.object ["compatible" A..= compatible, "current" A..= current, "unresolved" A..= unresolved], "schema" A..= schema, "authorizedForMutation" A..= False], current && matched)
  where
    applied (R.MigrationSummary _ state _ _) = state == R.Applied || state == R.Adopted
    required name = lookupEnv name >>= maybe (fail ("Missing " <> name)) (pure . Text.pack)
    checked = either (const (fail "Invalid explicit restored-inspection configuration")) pure

readPolicy :: FilePath -> IO (BS.ByteString, A.Value)
readPolicy path = withBinaryFile path ReadMode $ \handle -> do
  bytes <- BS.hGet handle 65537
  unless (BS.length bytes <= 65536) (fail "Expected policy document exceeds bound")
  document <- either (const (fail "Invalid expected policy JSON")) pure (A.eitherDecodeStrict' bytes)
  pure (bytes, document)

sqlLiteral :: Text -> Text
sqlLiteral value = "'" <> Text.replace "'" "\\'" (Text.replace "\\" "\\\\" value) <> "'"

fetchRows :: H.Manager -> T.DirectEndpoint -> Text -> Text -> Text -> Text -> IO [A.Value]
fetchRows manager url user secret expectedServer sql = do
  request <- H.parseRequest (Text.unpack (T.endpointText url))
  let query = "SELECT toString(serverUUID()) AS __server_id,version() AS __server_version," <> Text.drop 7 sql <> " FORMAT JSONEachRow"
      settings = [("max_execution_time", "30"), ("max_result_rows", "10000"), ("max_result_bytes", "1048576"), ("result_overflow_mode", "throw"), ("read_overflow_mode", "throw"), ("wait_end_of_query", "1")]
      checked = H.applyBasicAuth (Encoding.encodeUtf8 user) (Encoding.encodeUtf8 secret) request {H.method = "POST", H.redirectCount = 0, H.requestHeaders = [("Accept-Encoding", "identity"), ("Connection", "close")], H.queryString = renderQuery True [(key, Just value) | (key, value) <- settings], H.responseTimeout = H.responseTimeoutMicro 35000000, H.requestBody = H.RequestBodyBS (Encoding.encodeUtf8 query)}
  H.withResponse checked manager $ \response -> do
    unless (statusCode (H.responseStatus response) == 200) (fail "Read-only restored metadata unavailable or denied")
    bytes <- collect (H.responseBody response) BS.empty
    traverse decodeRow (filter (not . BS.null) (BS.split 10 bytes))
  where
    collect body acc = do
      chunk <- H.brRead body
      let next = acc <> chunk
      unless (BS.length next <= 1048576) (fail "Read-only restored metadata exceeds byte bound")
      if BS.null chunk then pure next else collect body next
    decodeRow bytes = do
      row <- either (const (fail "Incomplete restored metadata response")) pure (A.eitherDecodeStrict' bytes)
      unless (field "__server_id" row == A.String expectedServer && field "__server_version" row == field "serverVersion" Expected.document) (fail "Restored metadata server identity or qualified artifact differs")
      case row of
        A.Object fields -> pure (A.Object (KM.delete "__server_id" (KM.delete "__server_version" fields)))
        _ -> fail "Invalid restored metadata row"
