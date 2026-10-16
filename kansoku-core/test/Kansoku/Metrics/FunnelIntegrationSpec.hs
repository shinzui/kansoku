module Kansoku.Metrics.FunnelIntegrationSpec (spec) where

import ClickHaskell (Connection, command)
import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Time (fromGregorian)
import Effectful (Eff, IOE, runEff)
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Event
import Kansoku.Metrics.Api (FunnelMeasure (..), FunnelMode (..), MetricPoint, MetricResult, TimeGrain (..))
import Kansoku.Metrics.Filter qualified as Filter
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Query.Validate (QueryLimitError (..), SqlName, mkSqlName)
import Kansoku.Metrics.Registry (builtinMetric)
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = do
  describe "Kansoku.Funnel inputs" $ do
    it "rejects conflicting/excess exclusions, strict event filters and unsupported conversion dimensions before storage" $ do
      steps <- names ["a", "b"]
      x <- names ["a"]
      many <- names ["exclude" <> Text.pack (show i) | i <- [1 .. 21 :: Int]]
      field <- either (fail . Text.unpack) pure (Filter.mkMetricFilter "source" Filter.FilterEq (Just (Aeson.String "web")))
      let unused = error "funnel validation acquired storage"
          run options req = runEff (Query.runFunnelMetric defaultRegistry unused req Nothing options 10 steps)
      run (Query.FunnelOptions FunnelSequential FunnelCount x) (request "unused") `shouldReturn` limit "invalid_funnel_exclusion"
      run (Query.FunnelOptions FunnelSequential FunnelCount many) (request "unused") `shouldReturn` limit "too_many_funnel_exclusions"
      run (Query.FunnelOptions FunnelStrict FunnelCount []) ((request "unused") {Query.filters = [field]}) >>= (`shouldSatisfy` isCompileFailure)
      conversion unused ((request "unused") {Query.timeGrain = Just Day}) >>= (`shouldSatisfy` isCompileFailure)
      conversion unused ((request "unused") {Query.groupBy = Just ["prop:plan"]}) >>= (`shouldSatisfy` isCompileFailure)
  describe "Kansoku.Funnel native" $ do
    it "shares count, exclusions, exact timing and first-touch ownership across both routes" $ withClickHouse $ \connection -> do
      let account = "funnel-chains"
          rows =
            [ event account "exposure" "experiment_viewed" "one" "2026-07-01 00:00:00 UTC" & #properties .~ props [("experiment", "exp"), ("variant", "a")],
              event account "first" "a" "one" "2026-07-01 00:00:01 UTC" & #sourceService ?~ "first",
              event account "page" "page_view" "one" "2026-07-01 00:00:01.250 UTC",
              event account "blocked" "x" "one" "2026-07-01 00:00:01.500 UTC",
              event account "later" "a" "one" "2026-07-01 00:00:02 UTC" & #sourceService ?~ "later",
              event account "complete" "b" "one" "2026-07-01 00:00:02.750 UTC",
              event account "second-start" "a" "two" "2026-07-01 00:00:01 UTC",
              event account "second-page" "page_view" "two" "2026-07-01 00:00:01.250 UTC",
              event account "second-end" "b" "two" "2026-07-01 00:00:02 UTC",
              event account "pre-start" "a" "pre" "2026-07-01 00:00:00 UTC",
              event account "pre-exposure" "experiment_viewed" "pre" "2026-07-01 00:00:01 UTC" & #properties .~ props [("experiment", "exp"), ("variant", "a")],
              event account "pre-end" "b" "pre" "2026-07-01 00:00:02 UTC"
            ]
      insertEvents connection (reverse rows <> take 2 rows)
      steps <- names ["a", "b"]
      excluded <- names ["x"]
      experiment <- oneName "exp"
      withPool $ \pool -> do
        forM_ [Nothing, Just experiment] $ \variant -> do
          let req = (request account) {Query.groupBy = Just ["source_service", "country_code"]}
              run mode measure exclusions = metric (Query.runFunnelMetric defaultRegistry pool req variant (Query.FunnelOptions mode measure exclusions) 10 steps)
          sequential <- run FunnelSequential FunnelCount []
          counts "first" sequential `shouldBe` Map.fromList [("1", 1), ("2", 1)]
          strict <- run FunnelStrict FunnelCount []
          counts "first" strict `shouldBe` Map.fromList [("1", 1), ("2", 1)]
          timing <- run FunnelSequential FunnelTimeToConvert excluded
          [point ^. #value | point <- timing ^. #points, group "source_service" point == Just "first"] `shouldBe` [0.75, 0.75]
          all (\point -> group "country_code" point == Nothing) (timing ^. #points) `shouldBe` True
          strictTimes <- run FunnelStrict FunnelTimeToConvert []
          [point ^. #value | point <- strictTimes ^. #points, group "source_service" point == Just "first"] `shouldBe` [0.75, 0.75]
          if isNothing variant then counts "a" strict `shouldBe` Map.fromList [("1", 2), ("2", 0)] else counts "a" strict `shouldBe` Map.empty
        missing <- metric (Query.runFunnel pool ((request account) {Query.accountId = AccountId "other"}) 10 steps)
        map (view #value) (missing ^. #points) `shouldBe` [0, 0]

    it "uses only the first-step property schema and exact nearest-rank quantiles" $ withClickHouse $ \connection -> do
      let account = "funnel-properties"
          row user start finish = [event account (user <> "-a") "subscription_started" user start & #properties .~ props [("plan", "starter")], event account (user <> "-b") "page_view" user finish]
      insertEvents connection (row "one" "2026-07-01 00:00:00 UTC" "2026-07-01 00:00:00.001 UTC" <> row "two" "2026-07-01 00:00:00 UTC" "2026-07-01 00:00:01.001 UTC" <> row "three" "2026-07-01 00:00:00 UTC" "2026-07-01 00:00:03 UTC")
      steps <- names ["subscription_started", "page_view"]
      withPool $ \pool -> do
        result <- metric (Query.runFunnelMetric defaultRegistry pool ((request account) {Query.groupBy = Just ["prop:plan"]}) Nothing (Query.FunnelOptions FunnelSequential FunnelTimeToConvert []) 10 steps)
        [(group "prop:plan" point, group "measure" point, point ^. #value) | point <- result ^. #points] `shouldBe` [(Just "starter", Just "p50_seconds", 1.001), (Just "starter", Just "p90_seconds", 3)]

    it "bounds ordered conversion by the starting population and owns groups at the first start" $ withClickHouse $ \connection -> do
      let account = "ordered-conversion"
      insertEvents connection [event account "start-one" "signup_started" "one" "2026-07-01 00:00:01 UTC", event account "end-one" "signup_completed" "one" "2026-07-01 00:00:02 UTC", event account "end-only" "signup_completed" "only" "2026-07-01 00:00:02 UTC", event account "end-before" "signup_completed" "before" "2026-07-01 00:00:00 UTC", event account "start-before" "signup_started" "before" "2026-07-01 00:00:01 UTC", event account "start-alone" "signup_started" "alone" "2026-07-01 00:00:01 UTC"]
      withPool $ \pool -> do
        result <- conversion pool (request account) >>= either (fail . show) pure
        map (view #value) (result ^. #points) `shouldBe` [1 / 3]
        empty <- conversion pool ((request account) {Query.accountId = AccountId "empty"}) >>= either (fail . show) pure
        map (view #value) (empty ^. #points) `shouldBe` [0]

    it "keeps contamination separate from exclusive shares at every bucket grain and returns zero totals for absent experiments" $ withClickHouse $ \connection -> do
      let account = "diagnostics"
          exposure eid user stamp variant = event account eid "experiment_viewed" user stamp & #properties .~ props (("experiment", "exp") : [("variant", v) | Just v <- [variant]])
      insertEvents connection [exposure "a-first" "one" "2026-07-01 00:00:00 UTC" (Just "a"), exposure "b-second" "one" "2026-07-01 00:00:00 UTC" (Just "b"), exposure "b-repeat" "one" "2026-07-01 00:00:01 UTC" (Just "b"), exposure "missing" "missing" "2026-07-01 00:00:00 UTC" Nothing, exposure "next" "one" "2026-07-02 00:00:00 UTC" (Just "b")]
      experiment <- oneName "exp"
      absent <- oneName "absent"
      withPool $ \pool -> do
        forM_ [Nothing, Just Day, Just Week, Just Month] $ \grain -> do
          result <- metric (Query.runExperimentDiagnostics pool ((request account) {Query.timeGrain = grain}) (Just experiment))
          let days = Map.fromListWith (<>) [(point ^. #bucket, [point]) | point <- result ^. #points]
          forM_ (Map.elems days) $ \points -> do
            let total name = sum [point ^. #value | point <- points, group "measure" point == Just name]
            total "exposed_users" `shouldSatisfy` (<= 1)
            total "variant_share" `shouldBe` if total "exposed_users" == 0 then 0 else 1
          if grain == Just Day then sum [point ^. #value | point <- result ^. #points, group "measure" point == Just "exposed_users"] `shouldBe` 2 else pure ()
        whole <- metric (Query.runExperimentDiagnostics pool (request account) (Just experiment))
        diagnosticValues whole `shouldBe` Map.fromList [(("exposed_users", Nothing), 1), (("multiple_exposure", Nothing), 1), (("assigned_users", Just "a"), 1), (("assigned_users", Just "b"), 0), (("variant_share", Just "a"), 1), (("variant_share", Just "b"), 0)]
        zero <- metric (Query.runExperimentDiagnostics pool (request account) (Just absent))
        length (zero ^. #points) `shouldBe` 2
        all ((== 0) . view #value) (zero ^. #points) `shouldBe` True
        other <- metric (Query.runExperimentDiagnostics pool ((request account) {Query.accountId = AccountId "other"}) Nothing)
        length (other ^. #points) `shouldBe` 2

    it "applies final point limits and native resource errors to funnel arrays and diagnostics" $ withClickHouse $ \connection -> do
      seedCap connection "funnel-cap" 0 5000
      steps <- names ["a", "b"]
      experiment <- oneName "exp"
      withPool $ \pool -> do
        let req = (request "funnel-cap") {Query.groupBy = Just ["source_service"]}
        result <- metric (Query.runFunnelMetric defaultRegistry pool req Nothing Query.defaultFunnelOptions 10 steps)
        length (result ^. #points) `shouldBe` 10000
        seedCap connection "funnel-cap" 5000 1
        runEff (Query.runFunnelMetric defaultRegistry pool req Nothing Query.defaultFunnelOptions 10 steps) `shouldReturn` Left Query.MetricResultTooLarge
        seedDiagnostics connection 0 4999
        diagnostics <- metric (Query.runExperimentDiagnostics pool (request "diagnostic-cap") (Just experiment))
        length (diagnostics ^. #points) `shouldBe` 10000
        seedDiagnostics connection 4999 1
        runEff (Query.runExperimentDiagnostics pool (request "diagnostic-cap") (Just experiment)) `shouldReturn` Left Query.MetricResultTooLarge
      cfg <- clickHouseConfigFromConfig <$> requireConfig
      bracket (newQueryPoolWithLimits cfg 1 (MetricsQueryLimits 30 1)) closeQueryPool $ \pool -> do
        outcomes <- sequence [runEff (Query.runFunnel pool (request "funnel-cap") 10 steps), runEff (Query.runExperimentDiagnostics pool (request "diagnostics") (Just experiment))]
        forM_ outcomes (`shouldBe` Left Query.QueryResourceLimit)

request :: Text -> Query.QueryRequest
request account = Query.QueryRequest (AccountId account) (fromGregorian 2026 7 1) (fromGregorian 2026 7 3) Nothing Nothing [] False

event :: Text -> Text -> Text -> Text -> String -> AnalyticsEvent
event account eid name user stamp = baseEvent (EventId eid) (EventName name) Web (read stamp) (read stamp) & #accountId ?~ AccountId account & #userId ?~ UserId user & #sourceService ?~ "a"

props :: [(Aeson.Key, Text)] -> KM.KeyMap Aeson.Value
props = KM.fromList . map (\(key, value) -> (key, Aeson.String value))

names :: [Text] -> IO [SqlName]
names = traverse oneName

oneName :: Text -> IO SqlName
oneName = either (fail . Text.unpack) pure . mkSqlName

withPool :: (QueryPool -> IO a) -> IO a
withPool action = do
  cfg <- clickHouseConfigFromConfig <$> requireConfig
  bracket (newQueryPool cfg 1) closeQueryPool action

metric :: Eff '[IOE] (Either Query.QueryExecutionError MetricResult) -> IO MetricResult
metric action = runEff action >>= either (fail . show) pure

conversion :: QueryPool -> Query.QueryRequest -> IO (Either Query.QueryExecutionError MetricResult)
conversion pool req = case builtinMetric "conversion_rate" of
  Nothing -> fail "missing conversion metric"
  Just builtin -> runEff (Query.run defaultRegistry pool builtin req)

group :: Text -> MetricPoint -> Maybe Text
group key point = fromMaybe Nothing (Map.lookup key (point ^. #group))

counts :: Text -> MetricResult -> Map.Map Text Double
counts service result = Map.fromList [(fromMaybe "" (group "index" point), point ^. #value) | point <- result ^. #points, group "source_service" point == Just service]

diagnosticValues :: MetricResult -> Map.Map (Text, Maybe Text) Double
diagnosticValues result = Map.fromList [((fromMaybe "" (group "measure" point), group "variant" point), point ^. #value) | point <- result ^. #points]

isCompileFailure :: Either Query.QueryExecutionError a -> Bool
isCompileFailure (Left Query.QueryCompileFailure {}) = True
isCompileFailure _ = False

limit :: Text -> Either Query.QueryExecutionError MetricResult
limit code = Left (Query.QueryLimitFailure (QueryLimitError code (if code == "invalid_funnel_exclusion" then "a step cannot also be excluded" else "at most 20 distinct exclusions are supported")))

seedCap :: Connection -> Text -> Int -> Int -> IO ()
seedCap connection account offset count = command connection (fromString ("INSERT INTO analytics.events_raw(event_id,event_name,source,source_service,occurred_at,received_at,user_id,account_id,properties,context) SELECT concat('cap-',toString(number)),'a','web',concat('svc',toString(number)),toDateTime64('2026-07-01',3,'UTC'),toDateTime64('2026-07-01',3,'UTC'),concat('user',toString(number)),'" <> Text.unpack account <> "','{}','{}' FROM numbers(" <> show offset <> "," <> show count <> ")"))

seedDiagnostics :: Connection -> Int -> Int -> IO ()
seedDiagnostics connection offset count = command connection (fromString ("INSERT INTO analytics.events_raw(event_id,event_name,source,occurred_at,received_at,user_id,account_id,properties,context) SELECT concat('diag-',toString(number)),'experiment_viewed','web',toDateTime64('2026-07-01',3,'UTC'),toDateTime64('2026-07-01',3,'UTC'),concat('user',toString(number)),'diagnostic-cap',concat('{\"experiment\":\"exp\",\"variant\":\"v',toString(number),'\"}'),'{}' FROM numbers(" <> show offset <> "," <> show count <> ")"))
