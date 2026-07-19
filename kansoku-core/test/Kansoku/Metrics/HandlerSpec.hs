{-# LANGUAGE TypeApplications #-}

module Kansoku.Metrics.HandlerSpec (spec) where

import Data.Aeson (eitherDecode)
import Data.Text qualified as Text
import Kansoku.Api qualified as Api
import Kansoku.Api.Response qualified as Response
import Kansoku.Metrics.Handler (metricsServer)
import Kansoku.Metrics.RoutingSpec (sentinelIngestServer)
import Kansoku.Server (envelopeFormatters)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (status400)
import Network.Wai (Application)
import Network.Wai.Handler.Warp qualified as Warp
import Servant (Context (..), serveWithContext)
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Metrics.Handler" $ do
  it "rejects an invalid funnel step before forcing the query pool" $
    Warp.testWithApplication (pure validationApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      request <-
        HTTP.parseRequest
          ( "http://127.0.0.1:"
              <> show port
              <> "/metrics/funnel?from=2026-06-01&to=2026-06-08&steps=ok_step,bad%27step"
          )
      response <- HTTP.httpLbs request manager
      HTTP.responseStatus response `shouldBe` status400
      envelope <-
        case eitherDecode (HTTP.responseBody response) of
          Right value -> pure value
          Left err -> expectationFailure ("JSON decode failed: " <> err) >> fail err
      Response.code envelope `shouldBe` "invalid_funnel_step"
      Response.message envelope `shouldSatisfy` Text.isInfixOf "bad'step"

  it "rejects a funnel window outside 1..7776000 before forcing the query pool" $
    Warp.testWithApplication (pure validationApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      request <-
        HTTP.parseRequest
          ( "http://127.0.0.1:"
              <> show port
              <> "/metrics/funnel?from=2026-06-01&to=2026-06-08&steps=ok_step&window=0"
          )
      response <- HTTP.httpLbs request manager
      HTTP.responseStatus response `shouldBe` status400
      envelope <-
        case eitherDecode (HTTP.responseBody response) of
          Right value -> pure value
          Left err -> expectationFailure ("JSON decode failed: " <> err) >> fail err
      Response.code envelope `shouldBe` "invalid_funnel_window"
      Response.message envelope `shouldSatisfy` Text.isInfixOf "0"

validationApplication :: Application
validationApplication =
  serveWithContext
    Api.kansokuAPI
    (envelopeFormatters :. EmptyContext)
    Api.KansokuAPI
      { Api.ingest = sentinelIngestServer,
        Api.metrics = metricsServer (error "query pool must not be forced by validation")
      }
