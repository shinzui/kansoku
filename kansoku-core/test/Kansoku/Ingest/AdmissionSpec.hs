module Kansoku.Ingest.AdmissionSpec (spec, count) where

import Control.Concurrent.Async (mapConcurrently)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef)
import Data.Text.Encoding (encodeUtf8)
import Data.Time (addUTCTime)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as S
import Hasql.Statement qualified as Statement
import Kansoku.Api.Response
import Kansoku.Auth.Issue (issueKey)
import Kansoku.Auth.Token (Token (..))
import Kansoku.Auth.Types
import Kansoku.Config (loadConfig)
import Kansoku.Event
import Kansoku.Ingest.Api (ingestEvent)
import Kansoku.Ingest.Queue (eventsQueueName)
import Kansoku.Ingest.RequestContext (emptyRequestContext)
import Kansoku.Ingest.Service
import Kansoku.Observability (PipelineMetrics)
import Kansoku.PostgresTestSupport (withMigratedStore)
import Kansoku.Prelude
import Kansoku.Server (kansokuAppWithChecks)
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (status202, status429)
import Network.Wai.Handler.Warp qualified as Warp
import Pgmq qualified
import Prometheus qualified as P
import Servant (runHandler)
import Servant.Health (ProbeVerdict (Healthy))
import Test.Hspec

spec :: PipelineMetrics -> Spec
spec metrics = describe "Kansoku.Ingest.Admission" $
  it "shares credential admission across transports before normalization/quarantine/queue and serves typed 429 headers" $
    withMigratedStore $ \settings _ pool -> do
      cfg <- loadConfig >>= either (fail . show) pure
      now <- getCurrentTime
      clock <- newIORef 0
      let configured = cfg & #pgConnectionString .~ settings & #ingestMaxBatchLength .~ 3 & #ingestRatePerSec .~ 1 & #ingestRateBurst .~ 3 & #ingestQuarantine .~ True
          queue = eventsQueueName "admission_spec"
          account = AccountId "admission-account"
          invalid n = (baseEvent (EventId n) (EventName "page_leave") Web now now) & #properties .~ KM.singleton "durationMs" (Aeson.Number (-1))
          future = baseEvent (EventId "limited-future") (EventName "custom") Web (addUTCTime 10 now) now
      Pool.use pool (Pgmq.createQueue queue) >>= either (fail . show) pure
      (keyA, Token tokenA) <- issueKey pool WriteKey account "first" >>= either (fail . show) pure
      (_, Token tokenB) <- issueKey pool WriteKey account "second" >>= either (fail . show) pure
      service <- newIngestServiceWithClock (readIORef clock) configured metrics pool queue
      let principal = AuthenticatedPrincipal keyA WriteKey account
          unused = error "analytics dependencies must not be needed for ingest admission"
          app = kansokuAppWithChecks (pure Healthy) (pure Healthy) metrics configured unused pool service unused
      manager <- Http.newManager Http.defaultManagerSettings
      Warp.testWithApplication (pure app) $ \port -> do
        let post :: (ToJSON a) => String -> Text -> a -> IO (Http.Response LBS.ByteString)
            post path token body = do
              initial <- Http.parseRequest ("http://127.0.0.1:" <> show port <> path)
              Http.httpLbs initial {Http.method = "POST", Http.requestHeaders = [("Authorization", "Bearer " <> encodeUtf8 token), ("Content-Type", "application/json"), ("Origin", "https://allowed.example")], Http.requestBody = Http.RequestBodyLBS (Aeson.encode body)} manager
        acceptedInvalid <- post "/v1/batch" tokenA (ingestEvent <$> [invalid "bad-1", invalid "bad-2", invalid "bad-3"])
        Http.responseStatus acceptedInvalid `shouldBe` status202
        count pool "kansoku.ingest_rejections" `shouldReturn` 3
        adjustments <- vectorCounter (metrics ^. #ingestTimestampAdjustmentsTotal) ("clamped", "single")
        limited <- post "/v1/events" tokenA (ingestEvent future)
        Http.responseStatus limited `shouldBe` status429
        lookup "Retry-After" (Http.responseHeaders limited) `shouldBe` Just "1"
        lookup "Content-Type" (Http.responseHeaders limited) `shouldSatisfy` maybe False (BS8.isPrefixOf "application/problem+json")
        lookup "Access-Control-Expose-Headers" (Http.responseHeaders limited) `shouldBe` Just "Retry-After"
        case Aeson.eitherDecode (Http.responseBody limited) of
          Right details -> do
            (details :: ProblemDetails) ^. #code `shouldBe` "rate_limited"
            details ^. #retryable `shouldBe` True
          Left err -> expectationFailure err
        count pool "pgmq.q_admission_spec" `shouldReturn` 0
        count pool "kansoku.accepted_events" `shouldReturn` 0
        count pool "kansoku.ingest_rejections" `shouldReturn` 3
        vectorCounter (metrics ^. #ingestTimestampAdjustmentsTotal) ("clamped", "single") `shouldReturn` adjustments
        -- EP-39 adapts its body credential into this exact service call. Its
        -- public endpoint/origin tests land with that route, after EP-30.
        beacon <- runHandler (submitIngest service Beacon principal emptyRequestContext [ingestEvent future])
        case beacon of
          Right (KansokuRateLimited _ delay) -> delay `shouldBe` 1
          other -> expectationFailure (show other)
        secondKey <- post "/v1/events" tokenB (ingestEvent future)
        Http.responseStatus secondKey `shouldBe` status202
        count pool "pgmq.q_admission_spec" `shouldReturn` 1
        concurrent <- mapConcurrently (\_ -> post "/v1/events" tokenB (ingestEvent future)) [1 .. 4 :: Int]
        length (filter ((== status202) . Http.responseStatus) concurrent) `shouldBe` 2
        length (filter ((== status429) . Http.responseStatus) concurrent) `shouldBe` 2
        count pool "pgmq.q_admission_spec" `shouldReturn` 1

count :: Pool.Pool -> Text -> IO Integer
count pool table = fromIntegral <$> (Pool.use pool (S.statement () (Statement.preparable ("SELECT count(*) FROM " <> table) E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))) >>= either (fail . show) pure)

vectorCounter :: P.Vector (Text, Text) P.Counter -> (Text, Text) -> IO Double
vectorCounter vector labels = fromMaybe 0 . lookup labels <$> P.getVectorWith vector P.getCounter
