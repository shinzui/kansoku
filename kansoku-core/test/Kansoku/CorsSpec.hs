module Kansoku.CorsSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as BSL
import Kansoku.Server (ingestCors)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (HeaderName, status200)
import Network.Wai (Application, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Server.ingestCors" $ do
  it "answers ingest preflights with browser and future auth headers" $
    Warp.testWithApplication (pure (ingestCors Nothing sentinelApp)) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      response <- preflight manager port "https://sdk.example.com"
      HTTP.responseStatus response `shouldBe` status200
      header "Access-Control-Allow-Origin" response `shouldBe` Just "*"
      header "Access-Control-Allow-Methods" response `shouldSatisfy` maybe False (ByteString.isInfixOf "POST")
      header "Access-Control-Allow-Methods" response `shouldSatisfy` maybe False (ByteString.isInfixOf "GET")
      header "Access-Control-Allow-Headers" response `shouldSatisfy` containsAll ["Content-Type", "X-Api-Key", "Authorization"]
      header "Access-Control-Max-Age" response `shouldBe` Just "3600"

  it "makes the public schema catalog readable by browser clients" $
    Warp.testWithApplication (pure (ingestCors Nothing sentinelApp)) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      request <- HTTP.parseRequest (baseUrl port <> "/v1/schemas")
      response <- HTTP.httpLbs request {HTTP.requestHeaders = [("Origin", "https://sdk.example.com")]} manager
      HTTP.responseStatus response `shouldBe` status200
      header "Access-Control-Allow-Origin" response `shouldBe` Just "*"

  it "does not add CORS headers to the metrics surface" $
    Warp.testWithApplication (pure (ingestCors Nothing sentinelApp)) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      request <- HTTP.parseRequest (baseUrl port <> "/metrics/events")
      response <- HTTP.httpLbs request {HTTP.requestHeaders = [("Origin", "https://sdk.example.com")]} manager
      HTTP.responseStatus response `shouldBe` status200
      header "Access-Control-Allow-Origin" response `shouldBe` Nothing

  it "refuses an origin outside the configured allowlist" $
    Warp.testWithApplication (pure (ingestCors (Just ["https://allowed.example"]) sentinelApp)) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      response <- preflight manager port "https://evil.example"
      HTTP.responseStatus response `shouldNotBe` status200
      header "Access-Control-Allow-Origin" response `shouldBe` Nothing

sentinelApp :: Application
sentinelApp _request respond =
  respond (responseLBS status200 [("Content-Type", "text/plain")] "sentinel")

preflight :: HTTP.Manager -> Warp.Port -> ByteString -> IO (HTTP.Response BSL.ByteString)
preflight manager port origin = do
  request <- HTTP.parseRequest (baseUrl port <> "/v1/batch")
  HTTP.httpLbs
    request
      { HTTP.method = "OPTIONS",
        HTTP.requestHeaders =
          [ ("Origin", origin),
            ("Access-Control-Request-Method", "POST"),
            ("Access-Control-Request-Headers", "content-type, x-api-key, authorization")
          ]
      }
    manager

header :: HeaderName -> HTTP.Response body -> Maybe ByteString
header name = lookup name . HTTP.responseHeaders

containsAll :: [ByteString] -> Maybe ByteString -> Bool
containsAll expected = maybe False (\actual -> all (`ByteString.isInfixOf` actual) expected)

baseUrl :: Warp.Port -> String
baseUrl port = "http://127.0.0.1:" <> show port
