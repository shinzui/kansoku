{-# LANGUAGE TypeApplications #-}

module Kansoku.Ingest.BeaconSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isRight)
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef)
import Data.Text.Encoding (encodeUtf8)
import Data.UUID qualified as UUID
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as S
import Kansoku.Api.Response
import Kansoku.Auth.Issue (issueKey)
import Kansoku.Auth.Token (Token (..))
import Kansoku.Auth.Types
import Kansoku.Config (loadConfig)
import Kansoku.Event
import Kansoku.Ingest.AdmissionSpec (count)
import Kansoku.Ingest.Api
import Kansoku.Ingest.Handler (ingestServer)
import Kansoku.Ingest.Queue (eventsQueueName)
import Kansoku.Ingest.RequestContext (emptyRequestContext)
import Kansoku.Ingest.Service
import Kansoku.Metrics.RoutingSpec ()
import Kansoku.Observability (PipelineMetrics)
import Kansoku.PostgresTestSupport (withMigratedStore)
import Kansoku.Prelude
import Kansoku.Server (kansokuAppWithChecks)
import Network.HTTP.Client qualified as H
import Network.HTTP.Types
import Network.Wai.Handler.Warp qualified as Warp
import Pgmq qualified
import Servant (runHandler)
import Servant.API (JSON)
import Servant.Client (client, mkClientEnv, parseBaseUrl, runClientM)
import Servant.Client.Core.Auth (mkAuthenticatedRequest)
import Servant.Health (ProbeVerdict (Healthy))
import Test.Hspec

spec :: PipelineMetrics -> Spec
spec metrics = describe "Kansoku beacon perimeter" $ do
  it "rejects duplicate unescaped envelope keys and redacts every decode failure" $ do
    let invalid = ["{", "[]", "{}", "{\"writeKey\":\"ksk_w_secret\",\"batch\":\"ksk_w_secret\"}", "{\"writeKey\":\"ksk_w_a\",\"write\\u004bey\":\"ksk_w_b\",\"batch\":[]}", "{\"writeKey\":\"ksk_w_a\",\"batch\":[],\"batch\":[]}", "{\"writeKey\":\"ksk_w_a\",\"batch\":[]} trailing"]
    mapM_ (\bytes -> case decodeBeaconEnvelope bytes of Left err -> err `shouldBe` "invalid beacon envelope"; Right _ -> expectationFailure "ambiguous envelope accepted") invalid
    isRight (decodeBeaconEnvelope "{\"writeKey\":\"ksk_w_a\",\"batch\":[]}\n") `shouldBe` True

  it "permanently rejects incompatible beacon events without claims or queue work" $
    withMigratedStore $ \_ _ pool -> do
      cfg <- loadConfig >>= either (fail . show) pure
      let queue = eventsQueueName "beacon_json_spec"
          principal = AuthenticatedPrincipal (ApiKeyId UUID.nil) WriteKey (AccountId "beacon-json")
          object = KM.fromList [("a.b", Aeson.Number 1), ("a", Aeson.object ["b" Aeson..= (2 :: Int)])]
      Pool.use pool (Pgmq.createQueue queue) >>= either (fail . show) pure
      service <- newIngestService cfg metrics pool queue
      now <- getCurrentTime
      let bad = ingestEvent (baseEvent (EventId "bad") (EventName "custom") Web now now & #context .~ object)
      result <- runHandler (postBeacon (ingestServer service) (const (pure (IngestPrincipal principal emptyRequestContext))) (BeaconEnvelope "unused" [bad]))
      result `shouldBe` Right (KansokuOk (BatchAck 0 [RejectedEvent 0 (Just "bad") [renderValidationError (IncompatibleJsonPaths "context")]]))
      count pool "kansoku.accepted_events" `shouldReturn` 0
      count pool "pgmq.q_beacon_json_spec" `shouldReturn` 0

  it "uses actual body authentication, shared admission, original-event quarantine and both generic client media types" $
    withMigratedStore $ \settings _ pool -> do
      cfg <- loadConfig >>= either (fail . show) pure
      clock <- newIORef 0
      let configured = cfg & #pgConnectionString .~ settings & #corsAllowedOrigins ?~ ["https://allowed.example"] & #ingestMaxBodyBytes .~ 4096 & #ingestMaxBatchLength .~ 3 & #ingestRatePerSec .~ 1 & #ingestRateBurst .~ 3 & #ingestQuarantine .~ True
          queue = eventsQueueName "beacon_spec"
          account = AccountId "beacon-account"
          unused = error "beacon must not query analytics"
      Pool.use pool (Pgmq.createQueue queue) >>= either (fail . show) pure
      (_, Token key) <- issueKey pool WriteKey account "beacon" >>= either (fail . show) pure
      (_, Token serviceKey) <- issueKey pool ServiceToken account "service" >>= either (fail . show) pure
      (_, Token revokedKey) <- issueKey pool WriteKey account "revoked" >>= either (fail . show) pure
      Pool.use pool (S.script "UPDATE kansoku.api_keys SET revoked_at=now() WHERE description='revoked'") >>= either (fail . show) pure
      service <- newIngestServiceWithClock (readIORef clock) configured metrics pool queue
      let app = kansokuAppWithChecks (pure Healthy) (pure Healthy) metrics configured unused pool service unused
      now <- getCurrentTime
      let event n = ingestEvent (baseEvent (EventId n) (EventName "custom") Web now now)
          envelope token events = Aeson.encode (BeaconEnvelope token events)
      manager <- H.newManager H.defaultManagerSettings
      Warp.testWithApplication (pure app) $ \port -> do
        initial <- H.parseRequest ("http://127.0.0.1:" <> show port <> "/v1/beacon")
        let post media headers body = H.httpLbs initial {H.method = "POST", H.requestHeaders = (hContentType, media) : headers, H.requestBody = H.RequestBodyLBS body} manager
            allowed = [(hOrigin, "https://allowed.example")]
            invalid = [("application/json", [], "{}", 400), ("text/plain", [], "{", 400), ("text/plain", [], envelope "ksk_w_unknown" [event "unknown"], 401), ("application/json", [], envelope revokedKey [event "revoked"], 401), ("text/plain", [], envelope serviceKey [event "service"], 403), ("text/plain", [(hAuthorization, "Bearer " <> encodeUtf8 key)], envelope key [event "competing"], 400), ("text/plain", [("X-Api-Key", encodeUtf8 key)], "{}", 400), ("text/plain", [(hOrigin, "https://denied.example")], envelope key [event "denied"], 400), ("application/json", [], envelope key (event <$> ["a", "b", "c", "d"]), 413), ("text/plain", [], LBS.replicate 4097 32, 413)]
        mapM_
          ( \(media, headers, body, expected) -> do
              response <- post media headers body
              statusCode (H.responseStatus response) `shouldBe` expected
              H.responseBody response `shouldSatisfy` (not . BS.isInfixOf (encodeUtf8 key) . LBS.toStrict)
          )
          invalid
        count pool "pgmq.q_beacon_spec" `shouldReturn` 0
        count pool "kansoku.accepted_events" `shouldReturn` 0
        count pool "kansoku.ingest_rejections" `shouldReturn` 0
        -- Both clients are generated from the same BeaconAPI; each selects its
        -- declared media type and passes no credential header.
        url <- parseBaseUrl ("http://127.0.0.1:" <> show port)
        let context = mkAuthenticatedRequest () (const id)
            env = mkClientEnv manager url
            plain = client (Proxy @(BeaconAPI '[PlainTextJSON])) context
            json = client (Proxy @(BeaconAPI '[JSON])) context
        runClientM (plain (BeaconEnvelope key [event "shared-id"])) env `shouldReturn` Right (KansokuOk (BatchAck 1 []))
        runClientM (json (BeaconEnvelope key [event "shared-id"])) env `shouldReturn` Right (KansokuOk (BatchAck 1 []))
        let invalidEvent = ingestEvent ((baseEvent (EventId "bad-page") (EventName "page_view") Web now now) & #context .~ KM.singleton "safe" (Aeson.String "value"))
        mixed <- post "text/plain;charset=UTF-8" allowed (envelope key [invalidEvent])
        H.responseStatus mixed `shouldBe` status202
        case Aeson.eitherDecode (H.responseBody mixed) of
          Right (BatchAck accepted rejected) -> do accepted `shouldBe` 0; length rejected `shouldBe` 1
          Left err -> expectationFailure err
        count pool "pgmq.q_beacon_spec" `shouldReturn` 1
        count pool "kansoku.accepted_events" `shouldReturn` 1
        count pool "kansoku.ingest_rejections" `shouldReturn` 1
        limited <- post "text/plain" allowed (envelope key [event "limited"])
        H.responseStatus limited `shouldBe` status429
        lookup "Retry-After" (H.responseHeaders limited) `shouldBe` Just "1"
        lookup "Access-Control-Allow-Origin" (H.responseHeaders limited) `shouldBe` Just "https://allowed.example"
        batchRequest <- H.parseRequest ("http://127.0.0.1:" <> show port <> "/v1/batch")
        batchLimited <- H.httpLbs batchRequest {H.method = "POST", H.requestHeaders = [(hContentType, "application/json"), ("X-Api-Key", encodeUtf8 key)], H.requestBody = H.RequestBodyLBS (Aeson.encode [event "batch-limited"])} manager
        H.responseStatus batchLimited `shouldBe` status429
        count pool "pgmq.q_beacon_spec" `shouldReturn` 1
        -- No envelope/key is captured with the rejected individual event.
        -- Text search happens in SQL against the diagnostic payload itself.
        diagnostic <- Pool.use pool (S.script "DO $$ BEGIN IF EXISTS (SELECT 1 FROM kansoku.ingest_rejections WHERE payload::text LIKE '%writeKey%' OR payload::text LIKE '%ksk_w_%') THEN RAISE EXCEPTION 'credential leaked'; END IF; END $$")
        diagnostic `shouldBe` Right ()
