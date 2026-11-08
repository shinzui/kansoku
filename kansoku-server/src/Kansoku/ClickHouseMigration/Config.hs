-- | Administrative configuration is independent of application startup. Never
-- render this value: it owns credentials. Offline plan does not load it.
module Kansoku.ClickHouseMigration.Config
  ( Config,
    loadConfig,
    target,
    topology,
    parseTopology,
    loadTopology,
    sessionTarget,
    ledger,
    session,
    postgres,
    nativeConfig,
    ensureFreshInitialization,
    sessionBarrier,
  )
where

import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target qualified as T
import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (forM_, unless)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.IORef
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Kansoku.Admin.Coordination qualified as C
import Kansoku.ClickHouse.Topology qualified as Topology
import Network.HTTP.Client qualified as H
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Network.HTTP.Types.URI (renderQuery)
import System.Environment (lookupEnv)
import System.Timeout (timeout)

data Config = Config
  { target :: !T.TargetKey,
    topology :: !T.TargetTopology,
    ledger :: !T.LedgerId,
    session :: !(Maybe Text),
    postgres :: !(Maybe Text),
    endpoint :: !T.DirectEndpoint,
    username :: !Text,
    password :: !Text,
    credentials :: !T.Credentials
  }

-- Pure selectors are also used by offline plan; absence and empty differ.
parseTopology :: Maybe Text -> Maybe Text -> Maybe Text -> Either Text T.TargetTopology
parseTopology cluster replicas direct = do
  selected <- Topology.parseTopology cluster replicas
  case selected of
    Topology.Direct -> T.DirectServer <$> maybe (Left "Missing KANSOKU_CH_MIGRATION_SERVER_ID") (checked . T.serverId) direct
    Topology.Replicated name ids -> do
      unless (direct == Nothing) (Left "SERVER_ID must be absent for a replicated target")
      c <- checked (T.clusterName name)
      expected <- traverse (checked . T.serverId) ids
      case NE.nonEmpty expected of
        Just values -> Right (T.ReplicatedCluster c values)
        Nothing -> Left "Empty replica inventory"
  where
    checked = either (const (Left "Invalid migration topology")) Right

loadTopology :: Bool -> IO T.TargetTopology
loadTopology offline = do
  cluster <- env "KANSOKU_CH_MIGRATION_CLUSTER"
  replicas <- env "KANSOKU_CH_MIGRATION_REPLICA_IDS"
  direct <- env "KANSOKU_CH_MIGRATION_SERVER_ID"
  -- Offline direct inspection historically requires no server identity.
  let sid = if offline && cluster == Nothing && replicas == Nothing then Just "00000000-0000-0000-0000-000000000000" else direct
  either (fail . Text.unpack) pure (parseTopology cluster replicas sid)
  where
    env name = fmap Text.pack <$> lookupEnv name

sessionTarget :: Config -> C.SessionTarget
sessionTarget c = case topology c of
  T.DirectServer sid -> C.DirectTarget (T.serverIdText sid)
  T.ReplicatedCluster name ids -> C.ReplicatedTarget (T.clusterNameText name) (map T.serverIdText (NE.toList ids))

required :: String -> IO Text
required name = lookupEnv name >>= maybe (fail ("Missing " ++ name)) (pure . Text.pack)

valid :: Either e a -> IO a
valid = either (const (fail "Invalid migration target configuration")) pure

loadConfig :: IO Config
loadConfig = do
  key <- required "KANSOKU_CH_MIGRATION_TARGET" >>= valid . T.targetKey
  selected <- loadTopology False
  lid <- required "KANSOKU_CH_MIGRATION_LEDGER_ID" >>= valid . T.ledgerId
  url <-
    lookupEnv "KANSOKU_CH_MIGRATION_ENDPOINT" >>= \case
      Just value -> pure (Text.pack value)
      Nothing -> do
        host <- required "KANSOKU_CLICKHOUSE_HOST"
        port <- required "CLICKHOUSE_HTTP_PORT"
        pure ("http://" <> host <> ":" <> port)
  ep <- valid (T.directEndpoint url)
  user <- maybe "default" Text.pack <$> lookupEnv "KANSOKU_CLICKHOUSE_USER"
  secret <- required "KANSOKU_CLICKHOUSE_PASSWORD"
  auth <- valid (T.basicCredentials user secret)
  sidText <- fmap Text.pack <$> lookupEnv "KANSOKU_CH_MIGRATION_SESSION"
  -- Validate the UUID spelling through the public UUID boundary without
  -- retaining a native-ledger identity for the PostgreSQL session itself.
  mapM_ (valid . T.ledgerId) sidText
  pg <- fmap Text.pack <$> lookupEnv "PG_CONNECTION_STRING"
  pure (Config key selected lid sidText pg ep user secret auth)

nativeConfig :: Config -> Bool -> T.TargetConfig
nativeConfig c firstUse = case topology c of
  T.DirectServer sid -> T.targetConfig (target c) (endpoint c) sid namespace binding (credentials c) T.defaultHttpLimits
  T.ReplicatedCluster name ids -> either (const (error "Invalid validated replicated configuration")) id (T.replicatedTargetConfig (target c) (endpoint c) name ids namespace binding (credentials c) T.defaultHttpLimits)
  where
    namespace = either (const (error "Invalid fixed ledger namespace")) id (T.ledgerNamespace "kansoku_migration_ledger")
    binding = if firstUse then T.FirstUse else T.ExistingLedger (ledger c)

-- Inspect history under application exclusion before a first-use handler. An
-- initialized matching native ledger permits interrupted native recovery. With
-- absent/uninitialized history, application objects must not already exist.
ensureFreshInitialization :: Config -> IO ()
ensureFreshInitialization c = do
  observation <- I.history I.Observe (nativeConfig c False)
  initialized <- case observation of
    Left _ -> fail "Cannot verify native initialization history; fence retained"
    Right (R.HistoryReport _ _ (R.LedgerInitializedAt identity) _ _ _ _ _) -> do
      unless (identity == ledger c) (fail "Native ledger identity mismatch")
      pure True
    Right (R.HistoryReport _ _ presence _ _ _ _ _) -> case presence of
      R.LedgerMissing -> pure False
      R.LedgerUninitialized -> pure False
      _ -> fail "Unknown native initialization state"
  case topology c of
    T.DirectServer _ | initialized -> pure ()
    _ -> do
      missing <- newIORef (case topology c of T.DirectServer sid -> Set.singleton (T.serverIdText sid); T.ReplicatedCluster _ ids -> Set.fromList (map T.serverIdText (NE.toList ids)))
      result <- timeout 35000000 (observe initialized missing)
      case result of
        Just () -> pure ()
        Nothing -> readIORef missing >>= fail . ("Fresh initialization observation deadline expired; missing: " ++) . show . Set.toAscList
  where
    observe initialized progress = bracket (H.newManager (H.managerSetProxy H.noProxy tlsManagerSettings {H.managerIdleConnectionCount = 0, H.managerRetryableException = const False})) H.closeManager $ \manager -> do
      let expected = case topology c of
            T.DirectServer sid -> Set.singleton (T.serverIdText sid)
            T.ReplicatedCluster _ ids -> Set.fromList (map T.serverIdText (NE.toList ids))
          loop remaining missing
            | Set.null missing = pure ()
            | remaining == (0 :: Int) = fail ("Replica observation budget exhausted; missing: " ++ show (Set.toAscList missing))
            | otherwise = do
                row <- requestObservation manager
                sid <- case KM.lookup "id" row of Just (A.String value) -> pure value; _ -> refuse
                unless (Set.member sid expected) refuse
                unless (initialized || KM.lookup "count" row == Just (A.Number 0)) refuse
                case topology c of
                  T.DirectServer _ -> pure ()
                  T.ReplicatedCluster _ _ -> unless (KM.lookup "applicationEngine" row == Just (A.String "Replicated") && KM.lookup "ledgerEngine" row == Just (A.String "Replicated")) (fail "Both analytics and kansoku_migration_ledger must already use Replicated databases")
                unless (Set.member sid missing) (threadDelay 100000)
                writeIORef progress (Set.delete sid missing)
                loop (remaining - 1) (Set.delete sid missing)
      loop 64 expected
    requestObservation manager = do
      request <- H.parseRequest (Text.unpack (T.endpointText (endpoint c)))
      let checked =
            H.applyBasicAuth
              (Encoding.encodeUtf8 (username c))
              (Encoding.encodeUtf8 (password c))
              request
                { H.method = "POST",
                  H.redirectCount = 0,
                  H.requestHeaders = [("Accept-Encoding", "identity"), ("Connection", "close")],
                  H.responseTimeout = H.responseTimeoutMicro 30000000,
                  H.requestBody = H.RequestBodyBS "SELECT toString(serverUUID()) AS id,(SELECT toUInt32(count()) FROM system.tables WHERE database='analytics') AS count,(SELECT any(engine) FROM system.databases WHERE name='analytics') AS applicationEngine,(SELECT any(engine) FROM system.databases WHERE name='kansoku_migration_ledger') AS ledgerEngine FORMAT JSONEachRow"
                }
      H.withResponse checked manager $ \response -> do
        unless (statusCode (H.responseStatus response) == 200) (fail "Fresh initialization HTTP observation failed")
        bytes <- collect (H.responseBody response) BS.empty
        case A.eitherDecodeStrict' bytes of
          Right (A.Object row) -> pure row
          _ -> refuse
    refuse = fail "Existing application objects or unknown target: legacy import is unsupported; create a fresh owned stack"
    collect body acc = do
      chunk <- H.brRead body
      let next = acc <> chunk
      unless (BS.length next <= 65536) (fail "Fresh initialization observation exceeds bound")
      if BS.null chunk then pure next else collect body next

-- Synchronization is read-only with respect to application facts. ON CLUSTER
-- targets only the validated configured cluster; each expected UUID is then
-- observed independently through the original endpoint, never a discovered host.
-- These barriers can be repeated after recovery without replaying a clear/insert.
-- After synchronization, read the entire retained population (sequential=0):
-- quorum-only reads can hide synchronized historical nonquorum retention rows.
sessionBarrier :: Config -> Text -> IO ()
sessionBarrier c proof = bracket (H.newManager (H.managerSetProxy H.noProxy tlsManagerSettings {H.managerIdleConnectionCount = 0, H.managerRetryableException = const False})) H.closeManager $ \manager -> do
  let expected = case topology c of
        T.DirectServer sid -> Set.singleton (T.serverIdText sid)
        T.ReplicatedCluster _ ids -> Set.fromList (map T.serverIdText (NE.toList ids))
      request sql = do
        initial <- H.parseRequest (Text.unpack (T.endpointText (endpoint c)))
        let settings = [("wait_end_of_query", "1"), ("async_insert", "0"), ("max_result_rows", "0"), ("max_result_bytes", "0"), ("result_overflow_mode", "throw"), ("read_overflow_mode", "throw"), ("select_sequential_consistency", "0"), ("max_execution_time", "55"), ("receive_timeout", "55"), ("distributed_ddl_task_timeout", "55"), ("distributed_ddl_output_mode", "throw")]
            checked =
              H.applyBasicAuth
                (Encoding.encodeUtf8 (username c))
                (Encoding.encodeUtf8 (password c))
                initial
                  { H.method = "POST",
                    H.redirectCount = 0,
                    H.queryString = renderQuery True [(k, Just v) | (k, v) <- settings],
                    H.requestHeaders = [("Accept-Encoding", "identity"), ("Connection", "close")],
                    H.responseTimeout = H.responseTimeoutMicro 60000000,
                    H.requestBody = H.RequestBodyBS (Encoding.encodeUtf8 sql)
                  }
        H.withResponse checked manager $ \response -> do
          unless (statusCode (H.responseStatus response) == 200) (fail "Session reconstruction barrier failed; fence retained")
          let collect acc = do
                chunk <- H.brRead (H.responseBody response)
                let next = acc <> chunk
                unless (BS.length next <= 65536) (fail "Session barrier observation exceeds bound")
                if BS.null chunk then pure next else collect next
          collect BS.empty
      observe remaining budget
        | Set.null remaining = pure ()
        | budget == (0 :: Int) = fail "Session verification did not observe every expected replica; fence retained"
        | otherwise = do
            bytes <- request ("SELECT toString(serverUUID()) AS id,(" <> proof <> ") AS result FORMAT JSONEachRow")
            row <- case A.eitherDecodeStrict' bytes of Right (A.Object value) -> pure value; _ -> fail "Invalid session verification response"
            sid <- case KM.lookup "id" row of Just (A.String value) -> pure value; _ -> fail "Missing session verification UUID"
            unless (Set.member sid expected && KM.lookup "result" row == Just (A.Number 0)) (fail "Session verification differs from canonical state or target; fence retained")
            unless (Set.member sid remaining) (threadDelay 100000)
            observe (Set.delete sid remaining) (budget - 1)
  case topology c of
    T.DirectServer _ -> pure ()
    T.ReplicatedCluster name _ -> do
      let cluster = T.clusterNameText name
      bytes <- request ("SELECT arraySort(groupArray(toString(serverUUID()))) AS ids FROM clusterAllReplicas('" <> cluster <> "',system.one) FORMAT JSONEachRow")
      case A.eitherDecodeStrict' bytes of
        Right (A.Object row) | KM.lookup "ids" row == Just (A.toJSON (Set.toAscList expected)) -> pure ()
        _ -> fail "Session barrier cluster inventory differs; fence retained"
      _ <- request ("SYSTEM SYNC DATABASE REPLICA ON CLUSTER '" <> cluster <> "' analytics")
      forM_ ["events_raw", "retention_policy", "sessions"] $ \table -> do
        _ <- request ("SYSTEM SYNC REPLICA ON CLUSTER '" <> cluster <> "' analytics." <> table <> " STRICT")
        pure ()
  result <- timeout 35000000 (observe expected 64)
  case result of Just () -> pure (); Nothing -> fail "Session replica verification deadline expired; fence retained"
