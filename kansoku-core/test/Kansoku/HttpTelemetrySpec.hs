module Kansoku.HttpTelemetrySpec (spec, lifecycleChild) where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Exception (SomeException, bracket, finally, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.IORef
import Data.List (isInfixOf, nub)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Kansoku.Config (loadConfig)
import Kansoku.Server (bodySizeLimit, ingestCors, kansokuAppWithChecks, problemBoundary)
import Kansoku.Telemetry (Telemetry (..), makeHttpMiddlewareWithSink, makeTelemetry)
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Internal (ResponseReceived (..))
import Numeric (showHex)
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Exporter.InMemory (inMemoryListExporter)
import OpenTelemetry.Metric.Core qualified as Metric
import OpenTelemetry.Propagator (getGlobalTextMapPropagator, setGlobalTextMapPropagator)
import OpenTelemetry.Propagator.W3CTraceContext (w3cTraceContextPropagator)
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Id qualified as Id
import Servant.Health (ProbeVerdict (Healthy))
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.HttpTelemetry" $ do
  it "parents exactly one route-named server span and correlates its access record" $ withCapture $ \middleware exported logs -> do
    let request = metricRequest "?ignored=query-secret"
        app original respond = do
          rawQueryString original `shouldBe` rawQueryString request
          queryString original `shouldBe` queryString request
          respond (responseLBS status503 [] "body-secret")
    _ <- middleware app request (const (pure ResponseReceived))
    spans <- readIORef exported
    length spans `shouldBe` 1
    span' <- first spans
    OTel.spanKind span' `shouldBe` OTel.Server
    hot <- readIORef (OTel.spanHot span')
    OTel.hotName hot `shouldBe` "GET metrics/events"
    OTel.hotStatus hot `shouldBe` OTel.Error ""
    mode <- lookupEnv "OTEL_SEMCONV_STABILITY_OPT_IN"
    let attribute name = Attr.lookupAttribute (OTel.hotAttributes hot) name
        textAttribute = Just . OTel.AttributeValue . OTel.TextAttribute
    attribute "http.target" `shouldBe` (if mode == Just "http" then Nothing else textAttribute "/metrics/events")
    attribute "url.query" `shouldBe` (if mode `elem` [Just "http", Just "http/dup"] then textAttribute "" else Nothing)
    Id.traceIdBaseEncodedText Id.Base16 (OTel.traceId (OTel.spanContext span')) `shouldBe` "4bf92f3577b34da6a3ce929d0e0e4736"
    case OTel.spanParent span' of
      Nothing -> expectationFailure "missing remote parent"
      Just parent -> do
        ctx <- OTel.getSpanContext parent
        Id.spanIdBaseEncodedText Id.Base16 (OTel.spanId ctx) `shouldBe` "00f067aa0ba902b7"
        OTel.isRemote ctx `shouldBe` True
    records <- readIORef logs
    length records `shouldBe` 1
    record <- first records
    case Aeson.decodeStrict record of
      Just (Aeson.Object fields) -> do
        KeyMap.lookup "trace_id" fields `shouldBe` Just (Aeson.String "4bf92f3577b34da6a3ce929d0e0e4736")
        KeyMap.lookup "span_id" fields `shouldBe` Just (Aeson.String (Id.spanIdBaseEncodedText Id.Base16 (OTel.spanId (OTel.spanContext span'))))
        KeyMap.lookup "status" fields `shouldBe` Just (Aeson.Number 503)
      _ -> expectationFailure "invalid JSON record"
    let serialized = show hot <> show (OTel.spanContext span') <> show records
    mapM_ (\secret -> serialized `shouldSatisfy` (not . isInfixOf secret)) ["query-secret", "header-secret", "body-secret"]
    -- Checks the whole exported attribute/event/status snapshot in each semantic mode.
    serialized `shouldSatisfy` (not . isInfixOf "?ignored=")

  it "traces production success, typed auth failure and canonical probes without extra spans" $ withCapture $ \middleware exported logs -> do
    cfg <- loadConfig >>= either (fail . show) pure
    let unused = error "unexpected database access"
        app = kansokuAppWithChecks (pure Healthy) (pure Healthy) unused cfg unused unused unused
        request path = defaultRequest {rawPathInfo = path, pathInfo = pathParts path}
    mapM_ (\path -> middleware app (request path) (const (pure ResponseReceived))) ["/v1/schemas", "/metrics/events", "/health/ready"]
    spans <- readIORef exported
    names <- mapM (fmap OTel.hotName . readIORef . OTel.spanHot) spans
    names `shouldMatchList` ["GET v1/schemas", "GET metrics/events", "GET health/ready"]
    length <$> readIORef logs `shouldReturn` 2

  it "preserves query isolation and unique serving contexts under concurrent requests" $ withCapture $ \middleware exported logs -> do
    let send n = do
          let value = Text.pack (show n)
              hex = showHex n ""
              trace = replicate (32 - length hex) '0' <> hex
              request = (metricRequest ("?ignored=" <> TextEncoding.encodeUtf8 value)) {queryString = [("ignored", Just (TextEncoding.encodeUtf8 value))], requestHeaders = [("traceparent", BS8.pack ("00-" <> trace <> "-00f067aa0ba902b7-01"))]}
              app original respond = do
                queryString original `shouldBe` queryString request
                rawQueryString original `shouldBe` rawQueryString request
                respond (responseLBS status200 [] "")
          middleware app request (const (pure ResponseReceived))
    mapConcurrently_ send [1 .. 16 :: Int]
    spans <- readIORef exported
    length spans `shouldBe` 16
    records <- readIORef logs
    length records `shouldBe` 16
    let identifiers = fmap (OTel.spanId . OTel.spanContext) spans
    length (nub identifiers) `shouldBe` 16
    length (nub (fmap (OTel.traceId . OTel.spanContext) spans)) `shouldBe` 16

  it "records framework failures through the existing exception boundary and bounds unknown routes" $ withCapture $ \middleware exported _ -> do
    let app = problemBoundary (\_ _ -> ioError (userError "private-error"))
    _ <- middleware app (defaultRequest {rawPathInfo = "/unknown", pathInfo = ["unknown"]}) $ \response -> do
      responseStatus response `shouldBe` status500
      pure ResponseReceived
    spans <- readIORef exported
    span' <- first spans
    hot <- readIORef (OTel.spanHot span')
    OTel.hotName hot `shouldBe` "GET"
    show hot `shouldSatisfy` (not . isInfixOf "private-error")

  it "keeps oversized request secrets out of spans and records" $ withCapture $ \middleware exported logs -> do
    let consumeBody original respond = strictRequestBody original >> respond (responseLBS status200 [] "")
        app = ingestCors Nothing (problemBoundary (bodySizeLimit 8 consumeBody))
        request =
          (metricRequest "?ignored=query-secret")
            { requestMethod = "POST",
              rawPathInfo = "/v1/batch",
              pathInfo = ["v1", "batch"],
              requestBodyLength = KnownLength 100_000_000,
              requestHeaders = (hContentLength, "100000000") : requestHeaders (metricRequest ""),
              requestBody = pure "body-secret"
            }
    observed <- newIORef status200
    _ <- middleware app request $ \response -> writeIORef observed (responseStatus response) >> pure ResponseReceived
    readIORef observed `shouldReturn` status413
    snapshots <- readIORef exported >>= mapM (readIORef . OTel.spanHot)
    records <- readIORef logs
    mapM_ (\secret -> (show snapshots <> show records) `shouldSatisfy` (not . isInfixOf secret)) ["query-secret", "header-secret", "body-secret"]

  it "does not export beacon envelope credentials or forwarded addresses" $ withCapture $ \middleware exported logs -> do
    chunks <- newIORef ["{\"writeKey\":\"ksk_w_beacon-secret\",\"batch\":[]}"]
    let request =
          defaultRequest
            { requestMethod = "POST",
              rawPathInfo = "/v1/beacon",
              pathInfo = ["v1", "beacon"],
              requestHeaders = [(hContentType, "text/plain;charset=UTF-8"), ("X-Forwarded-For", "198.51.100.77")],
              requestBody = atomicModifyIORef' chunks (\case [] -> ([], ""); value : rest -> (rest, value))
            }
        app original respond = strictRequestBody original >> respond (responseLBS status202 [] "")
    _ <- middleware app request (const (pure ResponseReceived))
    snapshots <- readIORef exported >>= mapM (readIORef . OTel.spanHot)
    records <- readIORef logs
    length snapshots `shouldBe` 1
    mapM_ (\secret -> (show snapshots <> show records) `shouldSatisfy` (not . isInfixOf secret)) ["ksk_w_beacon-secret", "writeKey", "198.51.100.77"]

  it "serves without exporters and honors SDK_DISABLED over configured export" $ do
    originalProvider <- OTel.getGlobalTracerProvider
    originalPropagator <- getGlobalTextMapPropagator
    originalMeter <- Metric.getGlobalMeterProvider
    let restore = OTel.setGlobalTracerProvider originalProvider >> setGlobalTextMapPropagator originalPropagator >> Metric.setGlobalMeterProvider originalMeter
    flip finally restore $ do
      withVariables [("OTEL_TRACES_EXPORTER", Nothing), ("OTEL_EXPORTER_OTLP_ENDPOINT", Nothing), ("OTEL_METRICS_EXPORTER", Nothing)] $ do
        bracket makeTelemetry shutdownTelemetry $ \telemetry ->
          httpMiddleware telemetry (\_ respond -> respond (responseLBS status200 [] "")) defaultRequest (const (pure ResponseReceived)) >> pure ()
      withVariables [("OTEL_TRACES_EXPORTER", Just "console"), ("OTEL_SDK_DISABLED", Just "true"), ("OTEL_METRICS_EXPORTER", Just "otlp")] $ do
        bracket makeTelemetry shutdownTelemetry $ \telemetry -> do
          OTel.inSpan' (tracer telemetry) "disabled" OTel.defaultSpanArguments $ \span' ->
            OTel.isRecording span' `shouldReturn` False

first :: [a] -> IO a
first (x : _) = pure x
first [] = expectationFailure "expected captured value" >> fail "missing capture"

withVariables :: [(String, Maybe String)] -> IO a -> IO a
withVariables variables action = bracket (mapM (lookupEnv . fst) variables) restore (const (mapM_ set variables >> action))
  where
    set (key, Nothing) = unsetEnv key
    set (key, Just value) = setEnv key value
    restore previous = mapM_ set (zip (fmap fst variables) previous)

metricRequest :: BS.ByteString -> Request
metricRequest query =
  defaultRequest
    { rawPathInfo = "/metrics/events",
      pathInfo = ["metrics", "events"],
      rawQueryString = query,
      queryString = [("ignored", Just "query-secret")],
      requestHeaders = [("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"), (hAuthorization, "header-secret")]
    }

pathParts :: BS.ByteString -> [Text.Text]
pathParts = filter (not . Text.null) . Text.splitOn "/" . TextEncoding.decodeUtf8

withCapture :: (Middleware -> IORef [OTel.ImmutableSpan] -> IORef [BS.ByteString] -> IO a) -> IO a
withCapture action = bracket getGlobalTextMapPropagator setGlobalTextMapPropagator $ \_ -> do
  setGlobalTextMapPropagator w3cTraceContextPropagator
  (processor, exported) <- inMemoryListExporter
  provider <- OTel.createTracerProvider [processor] OTel.emptyTracerProviderOptions
  logs <- newIORef []
  let sink line = atomicModifyIORef' logs (\xs -> (line : xs, ()))
  middleware <- makeHttpMiddlewareWithSink provider sink
  action middleware exported logs `finally` do
    _ <- OTel.forceFlushTracerProvider provider Nothing
    _ <- OTel.shutdownTracerProvider provider Nothing
    pure ()

-- A subprocess must flush a buffered span on normal and exceptional bracket exit.
lifecycleChild :: IO ()
lifecycleChild = do
  mode <- lookupEnv "KANSOKU_TELEMETRY_LIFECYCLE_CHILD"
  result <- try @SomeException $ bracket makeTelemetry shutdownTelemetry $ \telemetry -> do
    OTel.inSpan' (tracer telemetry) "kansoku-lifecycle-flush-proof" OTel.defaultSpanArguments (const (pure ()))
    if mode == Just "exception" then ioError (userError "expected lifecycle unwind") else pure ()
  case (mode, result) of
    (Just "exception", Left _) -> pure ()
    (_, Right ()) -> pure ()
    (_, Left err) -> fail (show err)
