module Kansoku.Metrics.LimitsSpec (spec) where

import ClickHaskell (Connection)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, waitCatch, withAsync)
import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (writeIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Kansoku.QueryPoolSpec (Fault (..), Proxy (..), drained, through, withProxy)
import System.Timeout (timeout)

import Data.Text qualified as Text
import Data.Time (addDays, fromGregorian)
import Data.Time.Calendar qualified
import Effectful (runEff)
import Kansoku.Api.Response qualified as Response
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Event (AccountId (..), defaultRegistry)
import Kansoku.Metrics.Api (MetricResult, TimeGrain (Day))
import Kansoku.Metrics.HandlerSpec (validationApplicationWithPool)
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Query.Validate
import Kansoku.Metrics.Registry (BuiltinMetric, builtinMetric)
import Kansoku.Prelude
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (status200, status400)
import Network.Wai.Handler.Warp qualified as Warp
import System.Environment (getEnv, lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.Process (readProcessWithExitCode)
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Metrics.Limits" $ do
  it "admits positive ranges through 366 days and rejects empty, reversed and 367-day ranges" $ do
    validateDateRange start (addDays 1 start) `shouldBe` Right ()
    validateDateRange start (addDays 366 start) `shouldBe` Right ()
    mapM_ (\end -> fmap limitCode (leftValue (validateDateRange start end)) `shouldBe` Just "invalid_date_range") [start, addDays (-1) start]
    fmap limitCode (leftValue (validateDateRange start (addDays 367 start))) `shouldBe` Just "query_range_too_large"

  it "admits 20 ordered/repeated funnel steps and rejects 21 or zero" $ do
    validateSteps (replicate 20 ()) `shouldBe` Right ()
    fmap limitCode (leftValue (validateSteps (replicate 21 ()))) `shouldBe` Just "too_many_funnel_steps"
    fmap limitCode (leftValue (validateSteps ([] :: [()]))) `shouldBe` Just "invalid_funnel_steps"

  it "canonicalizes distinct retention offsets and enforces count and value bounds" $ do
    validateOffsets [10, 2, 1, 2] `shouldBe` Right [1, 2, 10]
    validateOffsets [1 .. 32] `shouldBe` Right [1 .. 32]
    validateOffsets [1, 365] `shouldBe` Right [1, 365]
    fmap limitCode (leftValue (validateOffsets [1 .. 33])) `shouldBe` Just "too_many_retention_days"
    mapM_ (\n -> fmap limitCode (leftValue (validateOffsets [n])) `shouldBe` Just "invalid_retention_days") [0, -1, 366]

  it "rejects invalid ranges in every direct execution function without acquiring storage" $ do
    metric <- builtin "events"
    let unused = error "validation acquired storage"
        bad = request & #to .~ start
        step = sqlName "step"
    results <-
      runEff $
        sequence
          [ Query.run defaultRegistry unused metric bad,
            Query.runSessions unused bad,
            Query.runRetention unused bad [1],
            Query.runFunnel unused bad 3600 [step],
            Query.runExperimentExposures unused bad Nothing,
            Query.runExperimentConversion unused bad step step,
            Query.runExperimentFunnel unused bad step 3600 [step]
          ]
    results `shouldSatisfy` all (\case Left (Query.QueryLimitFailure err) -> limitCode err == "invalid_date_range"; _ -> False)

  it "rejects limit violations over HTTP before acquiring storage on every implemented route" $
    Warp.testWithApplication (pure (validationApplicationWithPool (error "validation acquired storage"))) $ \port -> do
      manager <- Http.newManager Http.defaultManagerSettings
      let badRange = "from=2026-07-01&to=2026-07-01"
          routes = [("events", ""), ("page-views", ""), ("sessions", ""), ("feature-adoption", ""), ("conversion", ""), ("users", ""), ("revenue", ""), ("retention", ""), ("funnel", "&steps=step"), ("experiments", ""), ("experiments/conversion", "&experiment=exp&event=step"), ("experiments/funnel", "&experiment=exp&steps=step")]
      mapM_ (\(route, extra) -> assertProblem manager port ("/metrics/" <> route <> "?" <> badRange <> extra) "invalid_date_range") routes
      assertProblem manager port "/metrics/events?from=2026-01-01&to=2027-01-03" "query_range_too_large"
      assertProblem manager port ("/metrics/funnel?from=2026-07-01&to=2026-07-02&steps=" <> csv (replicate 21 "step")) "too_many_funnel_steps"
      assertProblem manager port ("/metrics/retention?from=2026-07-01&to=2026-07-02&days=" <> csv (fmap show [1 .. 33 :: Int])) "too_many_retention_days"
      assertProblem manager port "/metrics/retention?from=2026-07-01&to=2026-07-02&days=18446744073709551617" "invalid_retention_days"

  describe "native" $ do
    it "returns exactly 10000 complete property groups and rejects 10001 without poisoning the pool" $ withNativeFixture $ \_conn -> do
      fixtureSQL "TRUNCATE TABLE analytics.events_raw"
      fixtureSQL (paymentInsert 0 10000)
      withPool $ \pool -> do
        metric <- builtin "revenue"
        let grouped = request & #groupBy .~ Just ["prop:plan"]
        result <- success =<< runEff (Query.run defaultRegistry pool metric grouped)
        length (result ^. #points) `shouldBe` 10000
        sum (fmap (^. #value) (result ^. #points)) `shouldBe` 10000
        let groups = [value | point <- result ^. #points, Just value <- [lookupGroup "prop:plan" (point ^. #group)]]
        groups `shouldSatisfy` (\values -> values == sort values)
        fixtureSQL (paymentInsert 10000 1)
        runEff (Query.run defaultRegistry pool metric grouped) `shouldReturn` Left Query.MetricResultTooLarge
        queryReachable pool `shouldReturn` True
        empty <- success =<< runEff (Query.run defaultRegistry pool metric (grouped & #accountId .~ AccountId "absent"))
        empty ^. #points `shouldBe` []
        Warp.testWithApplication (pure (validationApplicationWithPool pool)) $ \port -> do
          manager <- Http.newManager Http.defaultManagerSettings
          -- The sentinel principal is acct_sentinel; the valid range still answers 200 with no data.
          response <- get manager port "/metrics/events?from=2026-01-01&to=2027-01-02"
          Http.responseStatus response `shouldBe` status200
          assertProblem manager port "/metrics/revenue?from=2026-07-01&to=2026-07-02&groupBy=prop:plan" "metric_result_too_large"

    it "applies the same complete-or-error cap to experiment series" $ withNativeFixture $ \_conn -> do
      fixtureSQL "TRUNCATE TABLE analytics.experiment_exposures"
      fixtureSQL (exposureInsert 0 10000)
      withPool $ \pool -> do
        result <- success =<< runEff (Query.runExperimentExposures pool request Nothing)
        length (result ^. #points) `shouldBe` 10000
        fixtureSQL (exposureInsert 10000 1)
        runEff (Query.runExperimentExposures pool request Nothing) `shouldReturn` Left Query.MetricResultTooLarge
        queryReachable pool `shouldReturn` True

    it "preserves numeric aggregate ordering for retention and both funnel families" $ withNativeFixture $ \_conn -> do
      fixtureSQL "TRUNCATE TABLE analytics.events_raw"
      fixtureSQL orderExposures
      fixtureSQL orderSteps
      fixtureSQL orderActivity
      fixtureSQL orderLateCohort
      withPool $ \pool -> do
        let range = request & #accountId .~ AccountId "acct_order" & #to .~ addDays 15 start
            steps = fmap (sqlName . ("step_" <>) . tshow) [1 .. 10 :: Int]
        retention <- success =<< runEff (Query.runRetention pool range [10, 2, 1])
        [(lookupGroup "cohort" (point ^. #group), lookupGroup "offset" (point ^. #group), point ^. #value) | point <- retention ^. #points]
          `shouldBe` [(Just cohort, Just offset, count) | (cohort, count) <- [("2026-07-01", 2), ("2026-07-04", 1)], offset <- ["0", "1", "2", "10"]]
        funnel <- success =<< runEff (Query.runFunnel pool range 3600 steps)
        [(lookupGroup "index" (point ^. #group), point ^. #value) | point <- funnel ^. #points]
          `shouldBe` [(Just (tshow index), 2) | index <- [1 .. 10 :: Int]]
        experiment <- success =<< runEff (Query.runExperimentFunnel pool range (sqlName "bound_exp") 3600 steps)
        [(lookupGroup "variant" (point ^. #group), lookupGroup "index" (point ^. #group), point ^. #value) | point <- experiment ^. #points]
          `shouldBe` [(Just variant, Just (tshow index), 1) | variant <- ["a", "b"], index <- [1 .. 10 :: Int]]
        -- Repeated executions must preserve both values and SQL order.
        runEff (Query.runFunnel pool range 3600 steps) `shouldReturn` Right funnel
        runEff (Query.runRetention pool range [1, 2, 10]) `shouldReturn` Right retention
        runEff (Query.runExperimentFunnel pool range (sqlName "bound_exp") 3600 steps) `shouldReturn` Right experiment

    it "classifies failures after disposal and propagates cancellation through real metric execution" $ withNativeFixture $ \_conn -> do
      cfg <- clickHouseConfigFromConfig <$> requireConfig
      withProxy cfg $ \proxy ->
        bracket (newQueryPool (through proxy cfg) 1) closeQueryPool $ \pool -> do
          queryReachable pool `shouldReturn` True
          writeIORef (fault proxy) Drop
          failed <- runEff (Query.runSessions pool request)
          failed `shouldSatisfy` (\case Left (Query.QueryStorageFailure _) -> True; _ -> False)
          drained proxy
          writeIORef (fault proxy) Pass
          _ <- success =<< runEff (Query.runSessions pool request)
          writeIORef (fault proxy) Stall
          timeout 750_000 (runEff (Query.runSessions pool request)) `shouldReturn` Nothing
          drained proxy
          writeIORef (fault proxy) Pass
          _ <- success =<< runEff (Query.runSessions pool request)
          writeIORef (fault proxy) Stall
          withAsync (runEff (Query.runSessions pool request)) $ \worker -> do
            threadDelay 20_000
            cancel worker
            waitCatch worker >>= (`shouldSatisfy` either (const True) (const False))
          drained proxy
          writeIORef (fault proxy) Pass
          _ <- success =<< runEff (Query.runSessions pool request)
          pure ()

start :: Data.Time.Calendar.Day
start = fromGregorian 2026 7 1

request :: Query.QueryRequest
request = Query.QueryRequest (AccountId "acct_sentinel") start (addDays 1 start) Nothing (Just Day) []

leftValue :: Either a b -> Maybe a
leftValue (Left value) = Just value
leftValue _ = Nothing

sqlName :: Text -> SqlName
sqlName = either (error . show) id . mkSqlName

builtin :: Text -> IO BuiltinMetric
builtin name = maybe (fail "missing builtin") pure (builtinMetric name)

success :: Either Query.QueryExecutionError MetricResult -> IO MetricResult
success = either (fail . show) pure

withPool :: (QueryPool -> IO a) -> IO a
withPool action = do
  cfg <- clickHouseConfigFromConfig <$> requireConfig
  bracket (newQueryPool cfg 1) closeQueryPool action

csv :: [String] -> String
csv = Text.unpack . Text.intercalate "," . fmap Text.pack

get :: Http.Manager -> Int -> String -> IO (Http.Response LBS.ByteString)
get manager port path = Http.parseRequest ("http://127.0.0.1:" <> show port <> path) >>= (`Http.httpLbs` manager)

assertProblem :: Http.Manager -> Int -> String -> Text -> Expectation
assertProblem manager port path expected = do
  response <- get manager port path
  Http.responseStatus response `shouldBe` status400
  case Aeson.eitherDecode (Http.responseBody response) of
    Right problem -> do
      Response.code problem `shouldBe` expected
      Response.retryable problem `shouldBe` False
    Left err -> expectationFailure err

paymentInsert :: Int -> Int -> Text
paymentInsert offset count =
  "INSERT INTO analytics.events_raw (event_id,event_name,source,occurred_at,received_at,user_id,account_id,properties,context) SELECT concat('bound_',toString(number)), 'payment_completed', 'web', toDateTime64('2026-07-01 12:00:00',3,'UTC'), toDateTime64('2026-07-01 12:00:01',3,'UTC'), concat('u',toString(number)), 'acct_sentinel', concat('{\"amount\":1,\"plan\":\"g',leftPad(toString(number),5,'0'),'\"}'), '{}' FROM numbers(" <> tshow offset <> "," <> tshow count <> ")"

exposureInsert :: Int -> Int -> Text
exposureInsert offset count =
  "INSERT INTO analytics.experiment_exposures SELECT 'acct_sentinel', 'bound_exp', concat('v',leftPad(toString(number),5,'0')), toDate('2026-07-01'), uniqCombinedState(toString(number)) FROM numbers(" <> tshow offset <> "," <> tshow count <> ") GROUP BY number"

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

-- Only the isolated launcher authorizes this fixture's destructive setup.
withNativeFixture :: (Connection -> Expectation) -> Expectation
withNativeFixture action = do
  enabled <- lookupEnv "KANSOKU_QUERY_LIMIT_FIXTURES"
  if enabled == Just "1"
    then withClickHouse action
    else do
      required <- lookupEnv "KANSOKU_REQUIRED_INTEGRATION"
      if required == Just "1"
        then expectationFailure "required isolated metric fixtures missing"
        else pendingWith "run nix develop -c python3 scripts/query-limits.py"

fixtureSQL :: Text -> Expectation
fixtureSQL sql = do
  port <- getEnv "CLICKHOUSE_TCP_PORT"
  (exitCode, _, err) <- readProcessWithExitCode "clickhouse-client" ["--host", "127.0.0.1", "--port", port, "--query", Text.unpack sql] ""
  if exitCode == ExitSuccess then pure () else expectationFailure err

orderPrefix :: Text
orderPrefix = "INSERT INTO analytics.events_raw (event_id,event_name,source,occurred_at,received_at,user_id,account_id,properties,context) "

orderExposures :: Text
orderExposures = orderPrefix <> "SELECT concat('exposure_',toString(number)), 'experiment_viewed', 'web', toDateTime64('2026-07-01 00:00:00',3,'UTC'), toDateTime64('2026-07-01 00:00:00',3,'UTC'), concat('order_user_',toString(number)), 'acct_order', concat('{\"experiment\":\"bound_exp\",\"variant\":\"',if(number=0,'a','b'),'\"}'), '{}' FROM numbers(2)"

orderSteps :: Text
orderSteps = orderPrefix <> "SELECT concat('step_',toString(u.number),'_',toString(s.number)), concat('step_',toString(s.number+1)), 'web', toDateTime64('2026-07-01 00:00:00',3,'UTC') + toIntervalSecond(s.number+1), toDateTime64('2026-07-01 00:00:30',3,'UTC'), concat('order_user_',toString(u.number)), 'acct_order', '{}', '{}' FROM numbers(2) u CROSS JOIN numbers(10) s"

orderActivity :: Text
orderActivity = orderPrefix <> "SELECT concat('active_',toString(number),'_',toString(offset)), 'active', 'web', toDateTime64('2026-07-01 00:00:00',3,'UTC') + toIntervalDay(offset), toDateTime64('2026-07-12 00:00:00',3,'UTC'), concat('order_user_',toString(number)), 'acct_order', '{}', '{}' FROM numbers(2) ARRAY JOIN [1,2,10] AS offset"

orderLateCohort :: Text
orderLateCohort = orderPrefix <> "SELECT concat('late_',toString(offset)), 'active', 'web', toDateTime64('2026-07-01 00:00:00',3,'UTC') + toIntervalDay(offset), toDateTime64('2026-07-15 00:00:00',3,'UTC'), 'order_late', 'acct_order', '{}', '{}' FROM numbers(1) ARRAY JOIN [3,4,5,13] AS offset"

lookupGroup :: Text -> Map.Map Text (Maybe Text) -> Maybe Text
lookupGroup key groups = Map.lookup key groups >>= id
