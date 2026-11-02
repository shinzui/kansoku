module Kansoku.Ingest.EnrichmentIntegrationSpec (spec) where

import ClickHaskell (ChString, ClickHaskell, Column, Connection, Select, select, unsafeMkSelect)
import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.HashMap.Strict qualified as HashMap
import Data.Text.Encoding qualified as Text
import Effectful (IOE, runEff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as S
import Hasql.Statement qualified as Statement
import Kansoku.Auth.Issue (issueKey)
import Kansoku.Auth.Token (Token (..))
import Kansoku.Auth.Types (CredentialKind (WriteKey))
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Event
import Kansoku.Ingest.GeoIPSpec qualified as GeoFixture
import Kansoku.Ingest.Queue (eventsQueueName)
import Kansoku.Ingest.Service (newIngestService)
import Kansoku.Observability (PipelineMetrics, newWriterHeartbeat)
import Kansoku.PostgresTestSupport
import Kansoku.Prelude
import Kansoku.Server (kansokuAppWithChecks)
import Kansoku.Writer.Batch (writerBatchHandler)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (status202)
import Network.Wai.Handler.Warp qualified as Warp
import Pgmq qualified
import Servant.Health (ProbeVerdict (Healthy))
import Shibuya.Batch (BatchInfo (..), BatchTrigger (TriggerSize), defaultBatchKey)
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Test.Hspec

spec :: PipelineMetrics -> Spec
spec metrics = describe "Kansoku.Enrichment native" $
  it "preserves first server enrichment through HTTP acceptance, queue decoding, native write and replay" $
    withClickHouse $ \connection -> withMigratedStore $ \settings _ pool -> do
      base <- requireConfig
      database <- GeoFixture.fixture
      let cfg = base & #pgConnectionString .~ settings & #ingestGeoipDb ?~ database & #ingestTrustedProxyCidrs .~ ["127.0.0.1/32"]
          queue = eventsQueueName "enrichment_native"
          account = AccountId "enrichment-native"
          missing = error "ingest does not use probe or metric dependencies"
      Pool.use pool (Pgmq.createQueue queue) >>= either (fail . show) pure
      (_, Token token) <- issueKey pool WriteKey account "owned enrichment consumer" >>= either (fail . show) pure
      service <- newIngestService cfg metrics pool queue
      let app = kansokuAppWithChecks (pure Healthy) (pure Healthy) metrics cfg pool service missing
          timestamp = read "2026-07-01 12:00:00 UTC"
          event =
            baseEvent (EventId "enriched-first") (EventName "page_view") Web timestamp timestamp
              & #userId
              ?~ UserId "identified"
              & #anonymousId
              ?~ AnonymousId "cookie"
              & #sessionId
              ?~ SessionId "session"
              & #url
              ?~ "https://shop.example/entry"
              & #utmSource
              ?~ "facebook"
              & #utmMedium
              ?~ "cpc"
              & #properties
              .~ KM.singleton "url" (Aeson.String "https://shop.example/entry")
              & #context
              .~ KM.fromList [("countryCode", Aeson.String "US"), ("browserFamily", Aeson.String "fake"), ("bot", Aeson.Bool False)]
          body = case Aeson.toJSON event of
            Aeson.Object object -> Aeson.Object (KM.insert "enrichment" (Aeson.object ["countryCode" Aeson..= ("US" :: Text)]) object)
            value -> value
      Warp.testWithApplication (pure app) $ \port -> do
        manager <- HTTP.newManager HTTP.defaultManagerSettings
        initial <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/v1/events")
        let post agent address =
              HTTP.httpLbs
                initial
                  { HTTP.method = "POST",
                    HTTP.requestHeaders = [("Authorization", "Bearer " <> Text.encodeUtf8 token), ("Content-Type", "application/json"), ("User-Agent", agent), ("X-Forwarded-For", address)],
                    HTTP.requestBody = HTTP.RequestBodyLBS (Aeson.encode body)
                  }
                manager
        first <- post edge "81.2.69.160"
        HTTP.responseStatus first `shouldBe` status202
        retried <- post "Mozilla/5.0 Chrome/130.0" "2001:218::"
        HTTP.responseStatus retried `shouldBe` status202
      payloads <- Pool.use pool (S.statement () queued) >>= either (fail . show) pure
      length payloads `shouldBe` 1
      payload <- case payloads of [single] -> pure single; _ -> fail "expected one accepted envelope"
      let encoded = LBS.toStrict (Aeson.encode payload)
      mapM_ (\secret -> encoded `shouldSatisfy` (not . BS.isInfixOf secret)) ["81.2.69.160", "2001:218::", Text.encodeUtf8 token]
      heartbeat <- newWriterHeartbeat
      let message = Message {envelope = Envelope {messageId = MessageId "enrichment-native-1", cursor = Nothing, partition = Nothing, enqueuedAt = Nothing, traceContext = Nothing, headers = Nothing, attempt = Nothing, attributes = HashMap.empty, payload}, lease = Nothing} :: Message '[IOE] Aeson.Value
          info = BatchInfo {batchKey = defaultBatchKey, size = 1, trigger = TriggerSize, partition = Nothing}
          write = runEff (writerBatchHandler metrics heartbeat (insertQueuedEvents connection) info (message :| []))
      void write
      void write
      raw <- values connection "SELECT toJSONString(tuple(browser_family,os_family,device_class,is_bot,channel,country_code,enrichment_version)) AS value FROM analytics.events_canonical WHERE account_id='enrichment-native'"
      raw `shouldBe` [Aeson.toJSON ([Aeson.String "edge", Aeson.String "windows", Aeson.String "desktop", Aeson.Bool False, Aeson.String "paid_social", Aeson.String "GB", Aeson.Number 1] :: [Aeson.Value])]
      bracket (newQueryPool (clickHouseConfigFromConfig cfg) 1) closeQueryPool $ \queryPool ->
        withIdentityQueryConnection queryPool "enrichment-native" "2026-07-01" "2026-07-03" $ \reader -> do
          rich <- values reader "SELECT toJSONString(tuple(browser_family,os_family,device_class,is_bot,channel,country_code,enrichment_version)) AS value FROM analytics.events_resolved_http(scope_all_accounts=0,scope_account='enrichment-native',scope_from=toDateTime64('2026-07-01',3,'UTC'),scope_to=toDateTime64('2026-07-03',3,'UTC'))"
          rich `shouldBe` raw
  where
    edge = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36 Edg/130.0"
    queued = Statement.preparable "SELECT message FROM pgmq.q_enrichment_native ORDER BY msg_id" E.noParams (D.rowList (D.column (D.nonNullable D.jsonb)))

newtype JsonRow = JsonRow {value :: BS.ByteString}
  deriving stock (Generic)
  deriving anyclass (ClickHaskell '[Column "value" ChString])

values :: Connection -> Text -> IO [Aeson.Value]
values connection sql = do
  rows <- concat <$> select (unsafeMkSelect (const (Text.encodeUtf8Builder sql)) :: Select '[Column "value" ChString] JsonRow) connection pure
  traverse (\(JsonRow bytes) -> either fail pure (Aeson.eitherDecodeStrict' bytes)) rows
