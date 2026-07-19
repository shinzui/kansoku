{-# LANGUAGE TypeApplications #-}

module Kansoku.LimitsSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (newIORef, readIORef, writeIORef)
import Kansoku.Api.Response (ErrorEnvelopeWire (..))
import Kansoku.Server (bodySizeLimit, ingestCors)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (status200, status413)
import Network.Wai (Application, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp qualified as Warp
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Server.bodySizeLimit" $
  it "returns a readable CORS 413 before the inner application consumes the body" $ do
    bodyConsumed <- newIORef False
    let sentinel :: Application
        sentinel request respond = do
          _body <- strictRequestBody request
          writeIORef bodyConsumed True
          respond (responseLBS status200 [] "sentinel")
    Warp.testWithApplication (pure (ingestCors Nothing (bodySizeLimit 10 sentinel))) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/v1/events")
      response <-
        HTTP.httpLbs
          request
            { HTTP.method = "POST",
              HTTP.requestHeaders =
                [ ("Content-Type", "application/json"),
                  ("Content-Length", "11"),
                  ("Origin", "https://sdk.example.com")
                ],
              HTTP.requestBody = HTTP.RequestBodyLBS (BSL.replicate 11 120)
            }
          manager
      HTTP.responseStatus response `shouldBe` status413
      lookup "Access-Control-Allow-Origin" (HTTP.responseHeaders response) `shouldBe` Just "*"
      envelope <- decodeBody @ErrorEnvelopeWire (HTTP.responseBody response)
      code envelope `shouldBe` "payload_too_large"
      message envelope `shouldBe` "request body exceeds the 10-byte limit"
      retryable envelope `shouldBe` False
      readIORef bodyConsumed `shouldReturn` False

decodeBody :: (Aeson.FromJSON a) => BSL.ByteString -> IO a
decodeBody body =
  case Aeson.eitherDecode body of
    Right value -> pure value
    Left err -> expectationFailure ("JSON decode failed: " <> err <> "; body: " <> show body) >> fail err
