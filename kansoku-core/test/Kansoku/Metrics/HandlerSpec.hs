{-# LANGUAGE TypeApplications #-}

module Kansoku.Metrics.HandlerSpec (spec, validationApplicationWithPool) where

import Data.Aeson (eitherDecode)
import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Kansoku.Api qualified as Api
import Kansoku.Api.Response qualified as Response
import Kansoku.Auth.Handler (authContextWith)
import Kansoku.ClickHouse (QueryPool)
import Kansoku.Event (defaultRegistry, schemaCatalog)
import Kansoku.Metrics.Handler (metricsServer)
import Kansoku.Metrics.RoutingSpec (sentinelContext, sentinelIngestServer, sentinelPrincipal)
import Kansoku.Server (envelopeFormatters)
import Kansoku.Users.Handler (usersServer)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (status400, status503)
import Network.Wai (Application)
import Network.Wai.Handler.Warp qualified as Warp
import Servant (Context (..), serveWithContext)
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Metrics.Handler" $ do
  it "rejects invalid and unsupported user selection before cohorts, definitions or query checkout" $
    Warp.testWithApplication (pure authenticatedValidationApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      traverse_
        (\(route, extra) -> assertBadRequest manager port ("/metrics/" <> route <> "?from=2026-07-01&to=2026-07-02&filter=user_id:eq:alice&filter=cohort:eq:00000000-0000-0000-0000-000000000001" <> extra) "invalid_metric" "")
        [("conversion", ""), ("organizations", ""), ("paths", "&start=page_view"), ("funnel", "&steps=a,b"), ("retention", ""), ("lifecycle", ""), ("stickiness", ""), ("experiments", "&experiment=exp"), ("experiments/conversion", "&experiment=exp&event=page_view"), ("experiments/funnel", "&experiment=exp&steps=a,b")]
      traverse_ (\route -> assertBadRequest manager port ("/metrics/" <> route <> "?from=2026-07-01&to=2026-07-02&filter=user_id:contains:alice&filter=cohort:eq:00000000-0000-0000-0000-000000000001") "invalid_metric" "") ["events", "custom"]

  it "rejects malformed contained-event names before cohort loading or query checkout" $
    Warp.testWithApplication (pure validationApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      traverse_
        (\names -> assertBadRequest manager port ("/metrics/sessions?from=2026-07-01&to=2026-07-02&containsEvent=" <> names <> "&filter=cohort:eq:missing") "invalid_contains_event" "")
        ["", ",", ",a", "a,", "a,,b", "%20", "A", "%C3%A9", "bad%27name", replicate 129 'a', concat (replicate 20 "a,") <> "a"]

  it "rejects invalid acquisition conversion options before cohort loading or storage" $
    Warp.testWithApplication (pure validationApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      let request suffix code = assertBadRequest manager port ("/metrics/acquisition?from=2026-07-01&to=2026-07-03&" <> suffix) code ""
      traverse_
        (\suffix -> request suffix "invalid_conversion_events")
        ["measure=converted_users", "measure=conversion_rate", "measure=converted_users&conversionEvents=", "measure=converted_users&conversionEvents=,a", "measure=converted_users&conversionEvents=a,", "measure=conversion_rate&conversionEvents=a,,b", "measure=converted_users&conversionEvents=bad%27name", "measure=conversion_rate&conversionEvents=" <> replicate 129 'a', "measure=converted_users&conversionEvents=" <> concat (replicate 20 "a,") <> "a", "conversionEvents=a", "measure=users&conversionEvents=a", "measure=converted_users&conversionEvents=&filter=cohort:eq:missing"]

  it "rejects invalid Custom definitions before forcing the query pool" $
    Warp.testWithApplication (pure validationApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      traverse_
        (\suffix -> assertBadRequest manager port ("/metrics/custom?from=2026-07-01&to=2026-07-02&" <> suffix) "invalid_metric" "")
        ["events=payment_completed&aggregation=sum&property=plan", "aggregation=count", "events=bad%27name&aggregation=count", "events=payment_completed&aggregation=ratio", "metric=x&events=payment_completed", "metric=x&quantile=0.75"]
      traverse_
        (\suffix -> assertBadRequest manager port ("/metrics/custom?from=2026-07-01&to=2026-07-02&" <> suffix) "invalid_metric" "")
        ["events=payment_completed&aggregation=percentile&property=amount" <> q | q <- ["", "&quantile=0", "&quantile=1", "&quantile=-0.1", "&quantile=1.1"]]
      traverse_
        (\suffix -> assertBadRequest manager port ("/metrics/custom?from=2026-07-01&to=2026-07-02&" <> suffix) "invalid_metric" "")
        ["events=payment_completed&aggregation=count&quantile=0.75", "events=payment_completed&aggregation=percentile&property=plan&quantile=0.75", "events=payment_completed&aggregation=percentile&property=amount&quantile=0.75&denominatorEvents=feature_used"]

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
  response <- HTTP.httpLbs request {HTTP.requestHeaders = [("Authorization", "Bearer ksk_s_fixture")]} manager
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
        Api.analyses = error "analysis routes unused in metric handler tests",
        Api.metricDefinitions = error "definition routes unused in metric handler tests",
        Api.users = usersServer (error "users PostgreSQL unused") (error "users ClickHouse unused"),
        Api.cohorts = error "cohort routes are unused in metric handler tests",
        Api.metrics = metricsServer pool,
        Api.schemas = pure (schemaCatalog defaultRegistry)
      }

-- Exercise the production authentication/validation boundary with an isolated principal.
authenticatedValidationApplication :: Application
authenticatedValidationApplication =
  serveWithContext
    Api.kansokuAPI
    (envelopeFormatters :. authContextWith (const (pure (Right (Just sentinelPrincipal)))))
    Api.KansokuAPI
      { Api.ingest = sentinelIngestServer,
        Api.analyses = error "analysis routes unused in metric handler tests",
        Api.metricDefinitions = error "definition lookup must not run",
        Api.users = usersServer (error "users unused") (error "users unused"),
        Api.cohorts = error "cohort routes unused",
        Api.metrics = metricsServer (error "query pool must not be forced"),
        Api.schemas = pure (schemaCatalog defaultRegistry)
      }
