{-# LANGUAGE TypeApplications #-}

module Kansoku.Metrics.PathsSpec (spec) where

import ClickHaskell (command)
import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (addUTCTime, fromGregorian)
import Effectful (runEff)
import Kansoku.Api.Response qualified as Response
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Event
import Kansoku.Metrics.Api (MetricPoint, MetricResult, PathBy (..))
import Kansoku.Metrics.Filter qualified as Filter
import Kansoku.Metrics.HandlerSpec (validationApplicationWithPool)
import Kansoku.Metrics.Query qualified as Q
import Kansoku.Metrics.RequestValidation (validateMetricRequest)
import Kansoku.Prelude
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (status200, status400)
import Network.Wai (defaultRequest, queryString, rawPathInfo)
import Network.Wai.Handler.Warp qualified as Warp
import Test.Hspec

spec :: Spec
spec = do
  describe "Kansoku.Paths inputs" $ do
    it "rejects invalid controls before storage and binds anchors and lists natively" $ do
      let invalid = [options {Q.pathSteps = 0}, options {Q.pathSteps = 11}, options {Q.pathTop = 0}, options {Q.pathTop = 21}, options {Q.pathWindow = 0}, options {Q.pathWindow = 7776001}, options {Q.pathStart = Nothing}, options {Q.pathEnd = Just "b"}, options {Q.pathStart = Just "bad'"}, options {Q.pathEvents = [""]}, options {Q.pathExclude = replicate 101 "a"}, options {Q.pathBy = PathRoute, Q.pathStart = Just "not-a-route"}]
      forM_ invalid $ \bad -> runEff (Q.runPaths defaultRegistry (error "invalid paths acquired storage") (request "unused") bad) >>= (`shouldSatisfy` isLeft)
      sql <- either (fail . show) pure (Q.buildPathsSQL defaultRegistry (request "unused") options {Q.pathBy = PathRoute, Q.pathStart = Just "/café'", Q.pathEvents = ["page_view"], Q.pathExclude = ["x"]})
      sql `shouldSatisfy` Text.isInfixOf "account_id = {account_id:String}"
      sql `shouldSatisfy` Text.isInfixOf "{path_anchor:String}"
      sql `shouldSatisfy` Text.isInfixOf "{path_event_1:String}"
      sql `shouldSatisfy` Text.isInfixOf "{path_exclude_1:String}"
      sql `shouldSatisfy` (not . Text.isInfixOf "/café'")
      sql `shouldSatisfy` Text.isInfixOf "ORDER BY sort_step, value DESC, sort_from, sort_to\nLIMIT 10001"

    it "rejects unsupported and repeated controls in the authenticated parameter guard" $ do
      let validate query = validateMetricRequest defaultRequest {rawPathInfo = "/metrics/paths", queryString = query}
      validate [("groupBy", Just "route")] `shouldSatisfy` isLeft
      validate [("exclude", Just "a"), ("exclude", Just "b")] `shouldSatisfy` isLeft
      validate [("start", Just "a"), ("start", Just "b")] `shouldSatisfy` isLeft
      validate [("events", Just "a,b"), ("exclude", Just "b")] `shouldBe` Right ()

    it "returns HTTP 400 problem codes for invalid path options" $
      Warp.testWithApplication (pure (validationApplicationWithPool (error "invalid path HTTP acquired storage"))) $ \port -> do
        manager <- HTTP.newManager HTTP.defaultManagerSettings
        forM_ ["start=a&steps=11", "start=a&top=21", "start=a&window=0", "start=a&end=b", "by=event", "by=route&start=bad", "start=a&events=a,,b"] $ \params -> do
          req <- HTTP.parseRequest (baseUrl port <> params)
          response <- HTTP.httpLbs req manager
          HTTP.responseStatus response `shouldBe` status400
          problem <- either fail pure (Aeson.eitherDecode (HTTP.responseBody response))
          Response.code problem `shouldBe` "invalid_path_options"

  describe "Kansoku.Paths native" $ do
    it "counts one first-anchored sequence per user, folds top K, and filters before walking" $ withClickHouse $ \conn -> do
      let rows =
            concat [chain "paths-events" user ["signup_completed", "page_view", "onboarding_started", "feature_used"] | user <- ["one", "two"]]
              <> chain "paths-events" "drop" ["signup_completed"]
              <> chain "paths-events" "repeat" ["signup_completed", "signup_completed", "feature_used"]
              <> chain "other-account" "one" ["signup_completed", "wrong"]
          opts = options {Q.pathStart = Just "signup_completed", Q.pathExclude = ["page_view"]}
      insertEvents conn (reverse rows <> take 2 rows)
      withPool $ \pool -> do
        result <- run pool "paths-events" opts
        edges result `shouldBe` [("1", "signup_completed", "onboarding_started", 2), ("1", "signup_completed", "(end)", 1), ("1", "signup_completed", "signup_completed", 1), ("2", "onboarding_started", "feature_used", 2), ("2", "signup_completed", "feature_used", 1), ("3", "feature_used", "(end)", 3)]
        foldedResult <- run pool "paths-events" opts {Q.pathTop = 1}
        take 2 (edges foldedResult) `shouldBe` [("1", "(other)", "(other)", 2), ("1", "signup_completed", "onboarding_started", 2)]
        allowed <- run pool "paths-events" opts {Q.pathEvents = ["signup_completed", "feature_used"], Q.pathSteps = 1}
        edges allowed `shouldBe` [("1", "signup_completed", "feature_used", 2), ("1", "signup_completed", "(end)", 1), ("1", "signup_completed", "signup_completed", 1)]
        selectionFilter <- either (fail . Text.unpack) pure (Filter.mkMetricFilter "event_name" Filter.FilterIn (Just (Aeson.toJSON (["signup_completed", "feature_used"] :: [Text]))))
        actual <- runEff (Q.runPaths defaultRegistry pool (request "paths-events") {Q.filters = [selectionFilter]} opts {Q.pathSteps = 1}) >>= either (fail . show) pure
        actual `shouldBe` allowed
        missing <- run pool "missing-account" opts
        edges missing `shouldBe` []

    it "uses millisecond and ID ties, an inclusive window, and the last end in reverse" $ withClickHouse $ \conn -> do
      insertEvents conn [event "paths-order" "00" "a" "u" "2026-07-01 00:00:00 UTC", event "paths-order" "01" "b" "u" "2026-07-01 00:00:00 UTC", event "paths-order" "02" "payment_completed" "u" "2026-07-01 00:00:00.001 UTC", event "paths-order" "03" "c" "u" "2026-07-01 00:00:01 UTC", event "paths-order" "04" "payment_completed" "u" "2026-07-01 00:00:01.001 UTC"]
      withPool $ \pool -> do
        forward <- run pool "paths-order" options {Q.pathWindow = 1}
        edges forward `shouldBe` [("1", "a", "b", 1), ("2", "b", "payment_completed", 1), ("3", "payment_completed", "c", 1), ("4", "c", "(end)", 1)]
        backward <- run pool "paths-order" options {Q.pathStart = Nothing, Q.pathEnd = Just "payment_completed", Q.pathWindow = 1}
        edges backward `shouldBe` [("1", "payment_completed", "c", 1), ("2", "c", "payment_completed", 1), ("3", "payment_completed", "(end)", 1)]

    it "collapses page routes, excludes bots, supports entry/reverse flows and UTF-8 native anchors" $ withClickHouse $ \conn -> do
      let page :: Text -> Int -> Text -> AnalyticsEvent
          page user i route = event "paths-pages" (user <> Text.pack (show i)) "page_view" user ("2026-07-01 00:00:0" <> show i <> " UTC") & #url ?~ ("https://example.com" <> route)
      insertEvents conn [page "one" (0 :: Int) "/pricing", page "one" 1 "/pricing?campaign=a", page "one" 2 "/signup", page "two" 0 "/pricing", page "bot" 0 "/pricing", page "bot" 1 "/wrong", page "unicode" 0 "/café'", page "unicode" 1 "/done"]
      command conn "ALTER TABLE analytics.events_raw UPDATE is_bot=1 WHERE account_id='paths-pages' AND user_id='bot' SETTINGS mutations_sync=1"
      withPool $ \pool -> do
        let opts = options {Q.pathBy = PathRoute, Q.pathStart = Just "/pricing"}
        result <- run pool "paths-pages" opts
        edges result `shouldBe` [("1", "/pricing", "(end)", 1), ("1", "/pricing", "/signup", 1), ("2", "/signup", "(end)", 1)]
        entry <- run pool "paths-pages" opts {Q.pathStart = Nothing}
        edges entry `shouldContain` [("1", "/pricing", "/signup", 1)]
        unicode <- run pool "paths-pages" opts {Q.pathStart = Just "/café'"}
        edges unicode `shouldBe` [("1", "/café'", "/done", 1), ("2", "/done", "(end)", 1)]
        reverseResult <- run pool "paths-pages" opts {Q.pathStart = Nothing, Q.pathEnd = Just "/signup"}
        edges reverseResult `shouldBe` [("1", "/signup", "/pricing", 1), ("2", "/pricing", "(end)", 1)]

    it "bounds high-cardinality answers to 210 points with numeric step ordering and conserved users" $ withClickHouse $ \conn -> do
      insertEvents conn (concat [chain "paths-cap" (Text.pack (show user)) ("a" : ["event-" <> Text.pack (show user) <> "-" <> Text.pack (show step) | step <- [1 .. 10 :: Int]]) | user <- [1 .. 21 :: Int]])
      withPool $ \pool -> do
        result <- run pool "paths-cap" options {Q.pathSteps = 10, Q.pathTop = 20}
        length (edges result) `shouldBe` 210
        [step | (step, _, _, _) <- edges result] `shouldBe` concat [replicate 21 (Text.pack (show step)) | step <- [1 .. 10 :: Int]]
        Map.fromListWith (+) [(step, count) | (step, _, _, count) <- edges result] `shouldBe` Map.fromList [(Text.pack (show step), 21) | step <- [1 .. 10 :: Int]]
        foldedResult <- run pool "paths-cap" options {Q.pathSteps = 10, Q.pathTop = 1}
        take 1 (edges foldedResult) `shouldBe` [("1", "(other)", "(other)", 20)]
        length (edges foldedResult) `shouldBe` 20

    it "serves the real HTTP route and retains native resource failures" $ withClickHouse $ \conn -> do
      -- The validation app's authenticated sentinel owns account acct_sentinel.
      insertEvents conn (chain "acct_sentinel" "http-path" ["a", "b"])
      withPool $ \pool -> Warp.testWithApplication (pure (validationApplicationWithPool pool)) $ \port -> do
        manager <- HTTP.newManager HTTP.defaultManagerSettings
        req <- HTTP.parseRequest (baseUrl port <> "start=a&steps=1")
        response <- HTTP.httpLbs req manager
        HTTP.responseStatus response `shouldBe` status200
        result <- either fail pure (Aeson.eitherDecode (HTTP.responseBody response))
        edges result `shouldBe` [("1", "a", "b", 1)]
      cfg <- clickHouseConfigFromConfig <$> requireConfig
      bracket (newQueryPoolWithLimits cfg 1 (MetricsQueryLimits 30 1)) closeQueryPool $ \pool ->
        runEff (Q.runPaths defaultRegistry pool (request "acct_sentinel") options) `shouldReturn` Left Q.QueryResourceLimit

options :: Q.PathOptions
options = Q.PathOptions PathEvent (Just "a") Nothing 5 10 7776000 [] []

request :: Text -> Q.QueryRequest
request account = Q.QueryRequest (AccountId account) (fromGregorian 2026 7 1) (fromGregorian 2026 7 3) Nothing Nothing [] [] False

event :: Text -> Text -> Text -> Text -> String -> AnalyticsEvent
event account eid name user stamp = baseEvent (EventId eid) (EventName name) Web (read stamp) (read stamp) & #accountId ?~ AccountId account & #userId ?~ UserId user

chain :: Text -> Text -> [Text] -> [AnalyticsEvent]
chain account user names = [event account (account <> user <> Text.pack (show i)) name user (show (addUTCTime (fromIntegral i) (read "2026-07-01 00:00:00 UTC"))) | (i, name) <- zip [0 :: Int ..] names]

withPool :: (QueryPool -> IO a) -> IO a
withPool action = do
  cfg <- clickHouseConfigFromConfig <$> requireConfig
  bracket (newQueryPool cfg 1) closeQueryPool action

run :: QueryPool -> Text -> Q.PathOptions -> IO MetricResult
run pool account opts = runEff (Q.runPaths defaultRegistry pool (request account) opts) >>= either (fail . show) pure

edges :: MetricResult -> [(Text, Text, Text, Double)]
edges result = [(group "step" p, group "from" p, group "to" p, p ^. #value) | p <- result ^. #points]

group :: Text -> MetricPoint -> Text
group key point = fromMaybe "" (Map.findWithDefault Nothing key (point ^. #group))

baseUrl :: Warp.Port -> String
baseUrl port = "http://127.0.0.1:" <> show port <> "/metrics/paths?from=2026-07-01&to=2026-07-03&"
