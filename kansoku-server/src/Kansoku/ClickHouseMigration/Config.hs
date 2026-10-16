-- | Administrative configuration is independent of application startup. Never
-- render this value: it owns credentials. Offline plan does not load it.
module Kansoku.ClickHouseMigration.Config
  ( Config,
    loadConfig,
    target,
    server,
    ledger,
    session,
    postgres,
    nativeConfig,
    ensureFreshInitialization,
  )
where

import ClickHouseMigrate.Inspection qualified as I
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
import Network.HTTP.Client qualified as H
import Network.HTTP.Client.TLS (tlsManagerSettings)
import System.Environment (lookupEnv)
import System.Timeout (timeout)

data Config = Config
  { target :: !T.TargetKey,
    server :: !T.ServerId,
    ledger :: !T.LedgerId,
    session :: !(Maybe Text),
    postgres :: !(Maybe Text),
    endpoint :: !T.DirectEndpoint,
    username :: !Text,
    password :: !Text,
    credentials :: !T.Credentials
  }

required :: String -> IO Text
required name = lookupEnv name >>= maybe (fail ("Missing " ++ name)) (pure . Text.pack)

valid :: Either e a -> IO a
valid = either (const (fail "Invalid migration target configuration")) pure

loadConfig :: IO Config
loadConfig = do
  key <- required "KANSOKU_CH_MIGRATION_TARGET" >>= valid . T.targetKey
  sid <- required "KANSOKU_CH_MIGRATION_SERVER_ID" >>= valid . T.serverId
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
  pure (Config key sid lid sidText pg ep user secret auth)

nativeConfig :: Config -> Bool -> T.TargetConfig
nativeConfig c firstUse = T.targetConfig (target c) (endpoint c) (server c) namespace binding (credentials c) T.defaultHttpLimits
  where
    namespace = either (const (error "Invalid fixed ledger namespace")) id (T.ledgerNamespace "kansoku_migration_ledger")
    binding = if firstUse then T.FirstUse else T.ExistingLedger (ledger c)

-- Inspect history under application exclusion before a first-use handler. An
-- initialized matching native ledger permits interrupted native recovery. With
-- absent/uninitialized history, application objects must not already exist.
ensureFreshInitialization :: Config -> IO ()
ensureFreshInitialization c = do
  observation <- I.history I.Observe (nativeConfig c False)
  case observation of
    Left _ -> fail "Cannot verify native initialization history; fence retained"
    Right (R.HistoryReport _ _ (R.LedgerInitializedAt identity) _ _ _ _ _) ->
      unless (identity == ledger c) (fail "Native ledger identity mismatch")
    Right (R.HistoryReport _ _ presence _ _ _ _ _) -> case presence of
      R.LedgerMissing -> boundedEmptyApplication
      R.LedgerUninitialized -> boundedEmptyApplication
      _ -> fail "Unknown native initialization state"
  where
    boundedEmptyApplication = timeout 35000000 emptyApplication >>= maybe (fail "Fresh initialization observation deadline expired") pure
    emptyApplication = bracket (H.newManager (H.managerSetProxy H.noProxy tlsManagerSettings {H.managerIdleConnectionCount = 0, H.managerRetryableException = const False})) H.closeManager $ \manager -> do
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
                  H.requestBody = H.RequestBodyBS "SELECT toString(serverUUID()) AS id,toUInt32(count()) AS count FROM system.tables WHERE database='analytics' FORMAT JSONEachRow"
                }
      H.withResponse checked manager $ \response -> do
        -- Read a bounded complete response, including the EOF after its one row.
        bytes <- collect (H.responseBody response) BS.empty
        case A.eitherDecodeStrict' bytes of
          Right (A.Object row) -> unless (KM.lookup "id" row == Just (A.String (T.serverIdText (server c))) && KM.lookup "count" row == Just (A.Number 0)) refuse
          _ -> refuse
    refuse = fail "Existing application objects or unknown target: legacy import is unsupported; create a fresh owned stack"
    collect body acc = do
      chunk <- H.brRead body
      let next = acc <> chunk
      unless (BS.length next <= 65536) (fail "Fresh initialization observation exceeds bound")
      if BS.null chunk then pure next else collect body next
