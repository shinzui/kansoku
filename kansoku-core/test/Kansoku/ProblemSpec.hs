{-# LANGUAGE TypeApplications #-}

module Kansoku.ProblemSpec (spec) where

import Control.Exception (AsyncException (ThreadKilled), throwIO, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.OpenApi (validateToJSON)
import Data.Text qualified as Text
import Hasql.Pool qualified as Pool
import Kansoku.Api (kansokuAPI)
import Kansoku.Api qualified as Api
import Kansoku.Api.OpenApi ()
import Kansoku.Api.Response qualified as P
import Kansoku.Auth.Api (MetricsAuth)
import Kansoku.Auth.Handler (PrincipalLookup, authContextWith)
import Kansoku.Auth.Store (AuthStoreError (..))
import Kansoku.Auth.Token (Token (..), hashToken)
import Kansoku.Auth.Types (AuthenticatedPrincipal (..), CredentialKind (..))
import Kansoku.Metrics.Api qualified as Metrics
import Kansoku.Metrics.RoutingSpec (sentinelKansokuServer, sentinelPrincipal)
import Kansoku.Server (bodySizeLimit, envelopeFormatters, ingestCors, problemBoundary)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types
import Network.Wai (Application, defaultRequest, responseLBS, responseStream)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Internal (ResponseReceived (..))
import Servant (Context (..), serveWithContext)
import Servant.Client (ClientError (FailureResponse), ClientM, mkClientEnv, parseBaseUrl, runClientM)
import Servant.Client.Core.Auth (mkAuthenticatedRequest)
import Servant.Client.Core.Request qualified as ClientRequest
import Servant.Client.Core.Response qualified as ClientResponse
import Servant.Client.Generic (genericClient)
import Test.Hspec

spec :: Spec
spec = describe "RFC 9457 problems" $ do
  it "uses exactly the six contract keys and round-trips the reserved type field" $ do
    let problem = P.badRequest "malformed_request" "invalid request"
    case Aeson.toJSON problem of
      Aeson.Object fields ->
        sort (Key.toText <$> KeyMap.keys fields)
          `shouldBe` ["code", "detail", "retryable", "status", "title", "type"]
      value -> expectationFailure (show value)
    Aeson.eitherDecode (Aeson.encode problem) `shouldBe` Right problem
    validateToJSON problem `shouldBe` []
    P.problemType problem `shouldBe` "about:blank"
    P.title problem `shouldBe` "Bad Request"

  it "keeps catalog status, title and retry policy consistent for every stable code" $
    mapM_
      ( \(code, status) -> do
          let problem = P.problem status code "safe detail"
          P.code problem `shouldBe` code
          P.status problem `shouldBe` status
          P.retryable problem `shouldBe` (status == 503 || status == 429)
          validateToJSON problem `shouldBe` []
      )
      P.problemCatalog

  it "returns readable problems for parser, route, framework, and body-size failures" $
    Warp.testWithApplication (pure (appWith lookupPrincipal)) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      let cases =
            [ ("POST", "/v1/events", "application/json", "*/*", HTTP.RequestBodyLBS "{", status400, "malformed_request"),
              ("GET", "/metrics/events?from=nope&to=2026-06-02", "application/json", "*/*", HTTP.RequestBodyLBS "", status400, "malformed_request"),
              ("GET", "/missing", "application/json", "*/*", HTTP.RequestBodyLBS "", status404, "not_found"),
              ("POST", "/v1/schemas", "application/json", "*/*", HTTP.RequestBodyLBS "", status405, "method_not_allowed"),
              ("GET", "/v1/schemas", "application/json", "text/plain", HTTP.RequestBodyLBS "", status406, "not_acceptable"),
              ("POST", "/v1/events", "text/plain", "*/*", HTTP.RequestBodyLBS "{}", status415, "unsupported_media_type"),
              ("POST", "/v1/events", "application/json", "*/*", HTTP.RequestBodyLBS (LBS.replicate 4097 32), status413, "payload_too_large")
            ]
      mapM_
        ( \(method, path, ct, accept, body, expected, code) -> do
            request <- requestAt port path
            response <-
              HTTP.httpLbs
                request
                  { HTTP.method = method,
                    HTTP.requestHeaders = [(hContentType, ct), (hAccept, accept), ("X-Api-Key", "ksk_s_fixture"), (hOrigin, "https://example.com")],
                    HTTP.requestBody = body
                  }
                manager
            assertProblem expected code response
            if path == "/v1/events" && expected == status413
              then lookup "Access-Control-Allow-Origin" (HTTP.responseHeaders response) `shouldBe` Just "*"
              else pure ()
        )
        cases
      chunks <- newIORef [BS.replicate 4097 32]
      let nextChunk = atomicModifyIORef' chunks $ \case
            [] -> ([], BS.empty)
            chunk : rest -> (rest, chunk)
      request <- requestAt port "/v1/events"
      response <-
        HTTP.httpLbs
          request
            { HTTP.method = "POST",
              HTTP.requestHeaders = [(hContentType, "application/json"), ("X-Api-Key", "ksk_s_fixture"), (hOrigin, "https://example.com")],
              HTTP.requestBody = HTTP.RequestBodyStreamChunked ($ nextChunk)
            }
          manager
      assertProblem status413 "payload_too_large" response
      lookup "Access-Control-Allow-Origin" (HTTP.responseHeaders response) `shouldBe` Just "*"

  it "makes absent, malformed, unknown and revoked credentials indistinguishable" $
    Warp.testWithApplication (pure (appWith lookupPrincipal)) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      responses <-
        mapM
          ( \headers -> do
              request <- requestAt port "/metrics/events?from=2026-06-01&to=2026-06-02"
              response <- HTTP.httpLbs request {HTTP.requestHeaders = headers} manager
              assertProblem status401 "unauthorized" response
              lookup hWWWAuthenticate (HTTP.responseHeaders response) `shouldBe` Just "Bearer"
              pure (HTTP.responseBody response)
          )
          [[], [(hAuthorization, "Basic malformed")], [("X-Api-Key", "ksk_w_unknown")], [("X-Api-Key", "ksk_w_revoked")]]
      responses `shouldSatisfy` \case
        first : rest -> all (== first) rest
        [] -> False

  it "uses documented problem bodies for permission and credential-store failures" $ do
    let check lookupKey expected code =
          Warp.testWithApplication (pure (appWith lookupKey)) $ \port -> do
            manager <- HTTP.newManager HTTP.defaultManagerSettings
            request <- requestAt port "/metrics/events?from=2026-06-01&to=2026-06-02"
            response <- HTTP.httpLbs request {HTTP.requestHeaders = [("X-Api-Key", "ksk_w_fixture")]} manager
            assertProblem expected code response
    check lookupPrincipal status403 "forbidden"
    check (const (pure (Left (AuthStoreUsageError Pool.AcquisitionTimeoutUsageError)))) status503 "auth_store_unavailable"

  it "decodes pre-handler 401 and 403 problem bodies from generated-client failures" $
    Warp.testWithApplication (pure (appWith lookupPrincipal)) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      url <- parseBaseUrl ("http://127.0.0.1:" <> show port)
      let client = genericClient @Api.KansokuAPI @ClientM
          day = read "2026-06-01"
          credential token =
            mkAuthenticatedRequest @MetricsAuth
              ()
              (const (ClientRequest.addHeader "X-Api-Key" (token :: Text.Text)))
      mapM_
        ( \(token, status, code) -> do
            result <-
              runClientM
                (Metrics.events (Api.metrics client) (credential token) day day Nothing Nothing [])
                (mkClientEnv manager url)
            case result of
              Left (FailureResponse _ response) -> do
                ClientResponse.responseStatusCode response `shouldBe` status
                case Aeson.eitherDecode (ClientResponse.responseBody response) of
                  Right problem -> do
                    P.code problem `shouldBe` code
                    P.status problem `shouldBe` statusCode status
                    validateToJSON problem `shouldBe` []
                  Left err -> expectationFailure err
              other -> expectationFailure ("expected pre-handler failure, got " <> show other)
        )
        [("ksk_w_unknown", status401, "unauthorized"), ("ksk_w_fixture", status403, "forbidden")]

  it "sanitizes unexpected synchronous failures and propagates cancellation" $ do
    let failing _ _ = throwIO (userError "private password and SQL")
    Warp.testWithApplication (pure (problemBoundary failing)) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      request <- requestAt port "/metrics/events"
      response <- HTTP.httpLbs request manager
      assertProblem status500 "internal_error" response
      LBS.toStrict (HTTP.responseBody response) `shouldNotSatisfy` BS.isInfixOf "private"
    let cancelled _ _ = throwIO ThreadKilled
    result <- try @AsyncException (problemBoundary cancelled defaultRequest (const (pure ResponseReceived)))
    case result of
      Left ThreadKilled -> pure ()
      _ -> expectationFailure "asynchronous cancellation was swallowed"

  it "preserves framework headers, existing bodies and streaming responses" $ do
    let check inner expectedBody =
          Warp.testWithApplication (pure (problemBoundary inner)) $ \port -> do
            manager <- HTTP.newManager HTTP.defaultManagerSettings
            request <- requestAt port "/"
            response <- HTTP.httpLbs request manager
            HTTP.responseBody response `shouldBe` expectedBody
    check (\_ respond -> respond (responseLBS status415 [] "existing")) "existing"
    check (\_ respond -> respond (responseStream status415 [] (\write flush -> write "stream" >> flush))) "stream"
    Warp.testWithApplication (pure (problemBoundary (\_ respond -> respond (responseLBS status405 [(hAllow, "GET")] "")))) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      request <- requestAt port "/"
      response <- HTTP.httpLbs request manager
      assertProblem status405 "method_not_allowed" response
      lookup hAllow (HTTP.responseHeaders response) `shouldBe` Just "GET"

appWith :: PrincipalLookup -> Application
appWith lookupKey =
  ingestCors Nothing $
    problemBoundary $
      bodySizeLimit 4096 $
        serveWithContext kansokuAPI (envelopeFormatters :. authContextWith lookupKey) sentinelKansokuServer

lookupPrincipal :: PrincipalLookup
lookupPrincipal digest =
  pure . Right $
    Map.lookup digest $
      Map.fromList
        [ (hashToken (Token "ksk_s_fixture"), sentinelPrincipal),
          (hashToken (Token "ksk_w_fixture"), sentinelPrincipal {kind = WriteKey})
        ]

requestAt :: Warp.Port -> String -> IO HTTP.Request
requestAt port path = HTTP.parseRequest ("http://127.0.0.1:" <> show port <> path)

assertProblem :: Status -> Text.Text -> HTTP.Response LBS.ByteString -> Expectation
assertProblem expected expectedCode response = do
  HTTP.responseStatus response `shouldBe` expected
  lookup hContentType (HTTP.responseHeaders response) `shouldBe` Just "application/problem+json"
  case Aeson.eitherDecode (HTTP.responseBody response) of
    Left err -> expectationFailure (err <> ": " <> show (HTTP.responseBody response))
    Right problem -> do
      P.code problem `shouldBe` expectedCode
      P.status problem `shouldBe` statusCode expected
      P.title problem `shouldBe` Text.pack (showStatus expected)
      P.retryable problem `shouldBe` (expected == status503)
      validateToJSON problem `shouldBe` []
  where
    showStatus = map (toEnum . fromEnum) . BS.unpack . statusMessage
