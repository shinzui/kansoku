{-# LANGUAGE TypeApplications #-}

module Kansoku.Metrics.HandlerSpec (spec, validationApplicationWithPool) where

import Data.Aeson (eitherDecode)
import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Kansoku.Api qualified as Api
import Kansoku.Api.Response qualified as Response
import Kansoku.ClickHouse (QueryPool)
import Kansoku.Event (defaultRegistry, schemaCatalog)
import Kansoku.Metrics.Handler (metricsServer)
import Kansoku.Metrics.RoutingSpec (sentinelContext, sentinelIngestServer)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (status400, status503)
import Network.Wai (Application)
import Network.Wai.Handler.Warp qualified as Warp
import Servant (serveWithContext)
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Metrics.Handler" $ do
  it "rejects invalid funnel counting and attribution before storage on both routes" $
    Warp.testWithApplication (pure validationApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      traverse_
        ( \endpoint ->
            traverse_
              ( \control -> do
                  request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/metrics/" <> endpoint <> "?from=2026-06-01&to=2026-06-08&steps=a,b&" <> (if endpoint == "experiments/funnel" then "experiment=exp&" else "") <> control)
                  response <- HTTP.httpLbs request manager
                  HTTP.responseStatus response `shouldBe` status400
              )
              ["counting=bad", "attribution=step:0", "attribution=step:3", "attribution=step:999999999999999999999999999", "attribution=unknown", "mode=unknown"]
        )
        ["funnel", "experiments/funnel"]

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
      Response.detail envelope `shouldSatisfy` Text.isInfixOf "bad'step"

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
      Response.detail envelope `shouldSatisfy` Text.isInfixOf "0"

  it "rejects an undeclared property before forcing the query pool" $
    Warp.testWithApplication (pure validationApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      request <-
        HTTP.parseRequest
          ( "http://127.0.0.1:"
              <> show port
              <> "/metrics/revenue?from=2026-06-01&to=2026-06-08&groupBy=prop:nope"
          )
      response <- HTTP.httpLbs request manager
      HTTP.responseStatus response `shouldBe` status400
      envelope <-
        case eitherDecode (HTTP.responseBody response) of
          Right value -> pure value
          Left err -> expectationFailure ("JSON decode failed: " <> err) >> fail err
      Response.code envelope `shouldBe` "unknown_property"
      Response.detail envelope `shouldSatisfy` Text.isInfixOf "nope"

  it "rejects invalid experiment query inputs before forcing the query pool" $
    Warp.testWithApplication (pure validationApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      traverse_
        (\(path, expectedCode, messageFragment) -> assertBadRequest manager port path expectedCode messageFragment)
        [ ( "/metrics/experiments?from=2026-06-01&to=2026-06-08&experiment=bad%27name",
            "invalid_experiment_name",
            "bad'name"
          ),
          ( "/metrics/experiments?from=2026-06-01&to=2026-06-08&timeGrain=hour",
            "invalid_experiment_time_grain",
            "rollup is daily"
          ),
          ( "/metrics/experiments/conversion?experiment=bad%27name&event=purchase_completed&from=2026-06-01&to=2026-06-08",
            "invalid_experiment_name",
            "bad'name"
          ),
          ( "/metrics/experiments/conversion?experiment=checkout_v2&event=bad%27name&from=2026-06-01&to=2026-06-08",
            "invalid_event_name",
            "bad'name"
          ),
          ( "/metrics/experiments/conversion?experiment=checkout_v2&event=experiment_viewed&from=2026-06-01&to=2026-06-08",
            "invalid_conversion_event",
            "must differ"
          ),
          ( "/metrics/experiments/funnel?experiment=bad%27name&steps=checkout_started,purchase_completed&from=2026-06-01&to=2026-06-08",
            "invalid_experiment_name",
            "bad'name"
          ),
          ( "/metrics/experiments/funnel?experiment=checkout_v2&steps=checkout_started,bad%27step&from=2026-06-01&to=2026-06-08",
            "invalid_funnel_step",
            "bad'step"
          ),
          ( "/metrics/experiments/funnel?experiment=checkout_v2&steps=checkout_started,purchase_completed&from=2026-06-01&to=2026-06-08&window=0",
            "invalid_funnel_window",
            "0"
          )
        ]

  it "surfaces a query exception as HTTP 503 instead of a plausible result" $
    Warp.testWithApplication (pure validationApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      request <-
        HTTP.parseRequest
          ( "http://127.0.0.1:"
              <> show port
              <> "/metrics/sessions?from=2026-06-01&to=2026-06-08"
          )
      response <- HTTP.httpLbs request manager
      HTTP.responseStatus response `shouldBe` status503
      envelope <-
        case eitherDecode (HTTP.responseBody response) of
          Right value -> pure value
          Left err -> expectationFailure ("JSON decode failed: " <> err) >> fail err
      Response.code envelope `shouldBe` "clickhouse_unavailable"
      Response.retryable envelope `shouldBe` True

assertBadRequest :: HTTP.Manager -> Warp.Port -> String -> Text.Text -> Text.Text -> Expectation
assertBadRequest manager port path expectedCode messageFragment = do
  request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> path)
  response <- HTTP.httpLbs request manager
  HTTP.responseStatus response `shouldBe` status400
  envelope <-
    case eitherDecode (HTTP.responseBody response) of
      Right value -> pure value
      Left err -> expectationFailure ("JSON decode failed: " <> err) >> fail err
  Response.code envelope `shouldBe` expectedCode
  Response.detail envelope `shouldSatisfy` Text.isInfixOf messageFragment

validationApplication :: Application
validationApplication = validationApplicationWithPool (error "query pool must not be forced by validation")

validationApplicationWithPool :: QueryPool -> Application
validationApplicationWithPool pool =
  serveWithContext
    Api.kansokuAPI
    sentinelContext
    Api.KansokuAPI
      { Api.ingest = sentinelIngestServer,
        Api.cohorts = error "cohort routes are unused in metric handler tests",
        Api.metrics = metricsServer pool,
        Api.schemas = pure (schemaCatalog defaultRegistry)
      }
