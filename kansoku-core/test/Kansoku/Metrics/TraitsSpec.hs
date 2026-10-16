module Kansoku.Metrics.TraitsSpec (spec) where

import ClickHaskell (ChString, ClickHaskell, Column, Connection, Select, command, select, unsafeMkSelect)
import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (fromGregorian)
import Effectful (Eff, IOE, runEff)
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Event
import Kansoku.Ingest.QueuedEvent (QueuedEvent (..), enrichedQueuedEvent, legacyQueuedEvent)
import Kansoku.Ingest.RequestContext (emptyRequestContext)
import Kansoku.Metrics.Api (AcquisitionMeasure (..), CohortMode (..), FunnelMeasure (..), FunnelMode (..), MetricPoint, MetricResult, RetentionMode (..), SessionMeasure (..), UserWindow (..))
import Kansoku.Metrics.Filter qualified as Filter
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Query.Validate (mkSqlName)
import Kansoku.Metrics.Registry (builtinMetric)
import Kansoku.PersonProperties
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = do
  describe "Kansoku.Traits schema" $ do
    it "keeps identify v1 identity-only and pins governed smart constructors explicitly" $ do
      let legacy = (profile "schema" "v1" "identify" 1 "user" "2026-07-01 00:00:00 UTC" [("plan", Aeson.Null)]) {schemaVersion = Nothing}
      validateEvent legacy `shouldBe` Right legacy
      identifyEvent (EventId "a") Service now now Nothing (Just (UserId "u")) KM.empty ^. #schemaVersion `shouldBe` Just 2
      identifyOnceEvent (EventId "b") Service now now Nothing (Just (UserId "u")) KM.empty ^. #schemaVersion `shouldBe` Just 1
    it "requires user IDs, rejects null/type changes and admits only finite nonnegative integral company sizes" $ do
      let base = profile "schema" "v2" "identify" 2 "user" "2026-07-01 00:00:00 UTC" []
      validateEvent (base & #userId .~ Nothing) `shouldSatisfy` isLeft
      validateEvent (base & #eventName .~ EventName "identify_once" & #schemaVersion ?~ 1 & #userId ?~ UserId "") `shouldSatisfy` isLeft
      forM_ [Aeson.Null, Aeson.Bool True, Aeson.Array mempty, Aeson.Number (-1), Aeson.Number 1.25, readValue "1e9999", readValue "1e-9999", readValue "1.0000000000000000000001"] $ \invalid -> validateEvent (base & #properties .~ KM.singleton "company_size" invalid) `shouldSatisfy` isLeft
      forM_ [0, 1, 100] $ \valid -> validateEvent (base & #properties .~ KM.singleton "company_size" (Aeson.Number valid)) `shouldSatisfy` isRight
      validateEvent (base & #properties .~ KM.singleton "plan" Aeson.Null) `shouldSatisfy` isLeft
      validateEvent (base & #properties .~ KM.singleton "plan" (Aeson.String "")) `shouldSatisfy` isRight
      validateEvent (base & #schemaVersion ?~ 3) `shouldSatisfy` isLeft
      validateEvent (base & #eventName .~ EventName "identify_once" & #schemaVersion ?~ 2) `shouldSatisfy` isLeft
      case validateEvent (base & #properties .~ KM.singleton "company_size" (Aeson.Number 1.25)) of
        Left errors -> Text.intercalate "; " (map renderValidationError errors) `shouldSatisfy` Text.isInfixOf "finite integer >= 0"
        Right _ -> expectationFailure "fractional company size was accepted"
    it "persists first-acceptance eligibility in queue v2 and never promotes legacy or v1 envelopes" $ do
      let event = profile "queue" "profile" "identify" 2 "user" "2026-07-01 00:00:00 UTC" [("plan", Aeson.String "pro")]
          queued = enrichedQueuedEvent emptyRequestContext event
      queued ^. #traitsEligible `shouldBe` True
      Aeson.eitherDecode (Aeson.encode queued) `shouldBe` Right queued
      legacyQueuedEvent event ^. #traitsEligible `shouldBe` False
      let old = Aeson.object ["queueVersion" Aeson..= (1 :: Int), "event" Aeson..= event, "enrichment" Aeson..= (queued ^. #enrichment), "traitsEligible" Aeson..= True]
      case Aeson.fromJSON old of
        Aeson.Success (decoded :: QueuedEvent) -> decoded ^. #traitsEligible `shouldBe` False
        Aeson.Error failure -> expectationFailure failure
    it "publishes the same governed trait types for set and set-once without changing v1" $ do
      let schemas name version = maybe (error "missing trait schema") (view #properties) (lookupSchemaVersion (EventName name) version defaultRegistry)
      schemas "identify" 1 `shouldBe` []
      schemas "identify" 2 `shouldBe` governedTraits
      schemas "identify_once" 1 `shouldBe` governedTraits
    it "resolves user dimensions without an event scope and uses one pivot for repeated references" $ do
      selected <- input "user:plan" Filter.FilterEq (Aeson.String "pro")
      let req = (request "compile") {Query.groupBy = Just ["user:plan", "user:company_size"], Query.filters = [selected, selected]}
      metric <- maybe (fail "missing events") pure (builtinMetric "events")
      sql <- either (fail . show) pure (Query.buildSQL defaultRegistry metric req)
      Text.count "FROM analytics.user_traits" sql `shouldBe` 1
      sql `shouldSatisfy` Text.isInfixOf "e.subject_kind='user' AND e.subject_id=traits.user_id"
      Query.buildSQL defaultRegistry metric req {Query.groupBy = Just ["user:undeclared"]} `shouldSatisfy` isLeft

  describe "Kansoku.Traits native" $ do
    it "merges reversed/replayed state with total ties, latest-set precedence and earliest set-once fallback" $ withClickHouse $ \connection -> do
      let account = "trait-order"
          sample eid name version user stamp receive pairs = profile account eid name version user stamp pairs & #receivedAt .~ read receive
          rows =
            [ sample "once-a" "identify_once" 1 "one" "2026-07-01 00:00:01 UTC" "2026-07-01 00:00:03 UTC" [("plan", Aeson.String "initial"), ("country", Aeson.String "GB")],
              sample "once-z" "identify_once" 1 "one" "2026-07-01 00:00:01 UTC" "2026-07-01 00:00:03 UTC" [("country", Aeson.String "US")],
              sample "set-a" "identify" 2 "one" "2026-07-01 00:00:00 UTC" "2026-07-01 00:00:01 UTC" [("plan", Aeson.String "older")],
              sample "set-b" "identify" 2 "one" "2026-07-01 00:00:00 UTC" "2026-07-01 00:00:02 UTC" [("plan", Aeson.String "later-receive")],
              sample "set-z" "identify" 2 "one" "2026-07-01 00:00:00 UTC" "2026-07-01 00:00:02 UTC" [("plan", Aeson.String "\"quoted\""), ("company_size", Aeson.Number 10)],
              profile account "legacy" "identify" 1 "one" "2026-07-02 00:00:00 UTC" [("plan", Aeson.String "legacy")],
              profile account "invalid-event" "identify" 2 "one" "2026-07-03 00:00:00 UTC" [("plan", Aeson.String "invalid"), ("company_size", readValue "1.0000000000000000000001")],
              profile account "extra" "identify" 2 "one" "2026-07-03 00:00:00 UTC" [("unguarded", Aeson.String "ignored")]
            ]
      insertEvents connection (reverse rows <> rows)
      insertQueuedEvents connection [legacyQueuedEvent (profile account "old-queue" "identify" 2 "one" "2026-07-04 00:00:00 UTC" [("plan", Aeson.String "must-not-promote")])]
      actual <- traitRows connection account "one"
      actual `shouldBe` [Aeson.toJSON ("company_size" :: Text, "number" :: Text, "" :: Text, 10 :: Double), Aeson.toJSON ("country" :: Text, "string" :: Text, "GB" :: Text, 0 :: Double), Aeson.toJSON ("plan" :: Text, "string" :: Text, "\"quoted\"" :: Text, 0 :: Double)]
      rebuildUserTraits connection (AccountId account) (UserId "one")
      traitRows connection account "one" `shouldReturn` actual
      insertEvents connection rows
      traitRows connection account "one" `shouldReturn` actual
    it "does not admit invalid/anonymous traits, cross accounts or promote undeclared fields" $ withClickHouse $ \connection -> do
      let account = "trait-validity"
          base eid values = profile account eid "identify" 2 "one" "2026-07-01 00:00:00 UTC" values
      insertEvents connection [base "valid" [("plan", Aeson.String ""), ("company_size", readValue "1.2e2")], base "null" [("plan", Aeson.Null)], base "fraction" [("role", Aeson.String "no"), ("company_size", Aeson.Number 1.5)], base "tiny" [("role", Aeson.String "no"), ("company_size", readValue "1e-9999")], base "anonymous" [("role", Aeson.String "no")] & #userId .~ Nothing, base "other" [("plan", Aeson.String "other")] & #accountId ?~ AccountId "trait-other"]
      actual <- traitRows connection account "one"
      actual `shouldBe` [Aeson.toJSON ("company_size" :: Text, "number" :: Text, "" :: Text, 120 :: Double), Aeson.toJSON ("plan" :: Text, "string" :: Text, "" :: Text, 0 :: Double)]
    it "scrubs/deletes both states and sources, survives original replay/rebuild, and allows a new event" $ withClickHouse $ \connection -> do
      forM_ [("trait-erase-delete", DeleteTraitEvents), ("trait-erase-é", ScrubTraitEvents)] $ \(account, mode) -> do
        let user = "人"
            rows = [profile account "set" "identify" 2 user "2026-07-01 00:00:00 UTC" [("plan", Aeson.String "secret")], profile account "once" "identify_once" 1 user "2026-07-01 00:00:00 UTC" [("country", Aeson.String "secret")]]
        insertEvents connection rows
        eraseUserTraits connection (AccountId account) (UserId user) mode
        traitRows connection account user `shouldReturn` []
        if mode == ScrubTraitEvents then jsonValues connection ("SELECT toJSONString(properties_json) AS value FROM analytics.events_canonical WHERE account_id='" <> account <> "' ORDER BY event_id") `shouldReturn` [Aeson.Object KM.empty, Aeson.Object KM.empty] else pure ()
        insertEvents connection (reverse rows)
        rebuildUserTraits connection (AccountId account) (UserId user)
        traitRows connection account user `shouldReturn` []
        insertEvents connection [profile account "new" "identify_once" 1 user "2026-07-03 00:00:00 UTC" [("plan", Aeson.String "new")]]
        traitRows connection account user `shouldReturn` [Aeson.toJSON ("plan" :: Text, "string" :: Text, "new" :: Text, 0 :: Double)]
    it "segments stitched and anonymous populations, numeric traits, ordered conversion and whole sessions consistently" $ withClickHouse $ \connection -> do
      let account = "trait-metrics"
          alice = profile account "alice-identify" "identify" 2 "alice" "2026-07-02 00:00:00 UTC" [("plan", Aeson.String "pro"), ("company_size", Aeson.Number 10)] & #anonymousId ?~ AnonymousId "alice-cookie" & #sessionId ?~ SessionId "alice-session"
          row eid name user stamp = activity account eid name user stamp & #sessionId ?~ SessionId (user <> "-session")
          rows =
            [ row "alice-page" "page_view" "alice" "2026-07-01 00:00:00 UTC" & #userId .~ Nothing & #anonymousId ?~ AnonymousId "alice-cookie",
              alice,
              row "alice-start" "signup_started" "alice" "2026-07-01 00:00:01 UTC",
              row "alice-end" "signup_completed" "alice" "2026-07-01 00:00:02 UTC",
              row "alice-payment" "payment_completed" "alice" "2026-07-01 00:00:03 UTC" & #properties .~ KM.singleton "amount" (Aeson.Number 10),
              profile account "bob-identify" "identify_once" 1 "bob" "2026-07-02 00:00:00 UTC" [("plan", Aeson.String "free"), ("company_size", Aeson.Number 2)],
              row "bob-page" "page_view" "bob" "2026-07-01 00:00:00 UTC",
              row "bob-start" "signup_started" "bob" "2026-07-01 00:00:01 UTC",
              row "anonymous-page" "page_view" "unresolved" "2026-07-01 00:00:00 UTC" & #userId .~ Nothing & #anonymousId ?~ AnonymousId "alice"
            ]
      let exposed eid user stamp variant = row eid "experiment_viewed" user stamp & #properties .~ KM.fromList [("experiment", Aeson.String "trait_exp"), ("variant", Aeson.String variant)]
      insertEvents
        connection
        ( rows
            <> [ row "alice-old" "page_view" "alice" "2026-06-30 00:00:00 UTC" & #sessionId ?~ SessionId "alice-old-session",
                 exposed "alice-exposure-a" "alice" "2026-07-01 00:00:00 UTC" "a",
                 exposed "alice-exposure-b" "alice" "2026-07-01 00:00:00.500 UTC" "b",
                 exposed "bob-exposure" "bob" "2026-07-01 00:00:00 UTC" "a",
                 exposed "anon-exposure" "unresolved" "2026-07-01 00:00:00 UTC" "a" & #userId .~ Nothing & #anonymousId ?~ AnonymousId "alice"
               ]
        )
      pro <- input "user:plan" Filter.FilterEq (Aeson.String "pro")
      large <- input "user:company_size" Filter.FilterGt (Aeson.Number 2)
      steps <- either (fail . Text.unpack) pure (traverse mkSqlName ["signup_started", "signup_completed"])
      withPool $ \pool -> do
        let req = (request account) {Query.filters = [pro, large]}
        pointValues <$> builtin pool "page_views" req `shouldReturn` [1]
        sum . pointValues <$> metric (Query.runUsers defaultRegistry pool CalendarWindow req) `shouldReturn` 1
        pointValues <$> builtin pool "conversion_rate" req `shouldReturn` [1]
        sum . pointValues <$> builtin pool "revenue" req `shouldReturn` 10
        sum . pointValues <$> metric (Query.runUsers defaultRegistry pool Rolling7 req) `shouldReturn` 2
        sticky <- metric (Query.runStickiness defaultRegistry pool req)
        sum [point ^. #value | point <- sticky ^. #points, Map.lookup "measure" (point ^. #group) == Just (Just "daily_active")] `shouldBe` 1
        retained <- metric (Query.runRetentionMetric defaultRegistry pool RetentionOn WindowCohort req [1])
        pointValues retained `shouldBe` [1, 0]
        lifetime <- metric (Query.runRetentionMetric defaultRegistry pool RetentionOn LifetimeCohort req [1])
        pointValues lifetime `shouldBe` []
        life <- metric (Query.runLifecycle defaultRegistry pool req)
        sum [point ^. #value | point <- life ^. #points, Map.lookup "status" (point ^. #group) == Just (Just "returning")] `shouldBe` 1
        experiment <- either (fail . Text.unpack) pure (mkSqlName "trait_exp")
        conversionEvent <- either (fail . Text.unpack) pure (mkSqlName "signup_completed")
        let byTrait = req {Query.groupBy = Just ["user:plan"]}
        exposures <- metric (Query.runExperimentExposures pool byTrait (Just experiment))
        pointValues exposures `shouldBe` [1, 1]
        diagnostics <- metric (Query.runExperimentDiagnostics pool byTrait (Just experiment))
        length (diagnostics ^. #points) `shouldBe` 6
        sum [point ^. #value | point <- diagnostics ^. #points, Map.lookup "measure" (point ^. #group) == Just (Just "variant_share")] `shouldBe` 1
        converted <- metric (Query.runExperimentConversion pool byTrait experiment conversionEvent)
        pointValues converted `shouldBe` replicate 6 1
        forM_ [FunnelSequential, FunnelStrict] $ \mode -> do
          funnel <- metric (Query.runFunnelMetric defaultRegistry pool byTrait (Just experiment) (Query.FunnelOptions mode FunnelCount []) 10 steps)
          pointValues funnel `shouldBe` replicate 4 1

        forM_ [FunnelSequential, FunnelStrict] $ \mode -> do
          funnel <- metric (Query.runFunnelMetric defaultRegistry pool req Nothing (Query.FunnelOptions mode FunnelCount []) 10 steps)
          pointValues funnel `shouldBe` [1, 1]
        sessions <- metric (Query.runSessionMetric pool SessionCount req)
        sum (pointValues sessions) `shouldBe` 1
        acquired <- metric (Query.runAcquisition defaultRegistry pool AcquisitionSessions req)
        sum (pointValues acquired) `shouldBe` 1
        people <- metric (Query.runAcquisition defaultRegistry pool AcquisitionUsers req)
        sum (pointValues people) `shouldBe` 1
        grouped <- builtin pool "page_views" ((request account) {Query.groupBy = Just ["user:company_size", "user:plan"]})
        [(Map.lookup "user:company_size" (point ^. #group), point ^. #value) | point <- grouped ^. #points] `shouldBe` [(Just Nothing, 1), (Just (Just "2"), 1), (Just (Just "10"), 1)]
        empty <- builtin pool "page_views" req {Query.accountId = AccountId "trait-metrics-other"}
        pointValues empty `shouldBe` []

    it "attributes all session events to the first resolved user's current traits, even when users change" $ withClickHouse $ \connection -> do
      let account = "trait-session-primary"
          row eid name user stamp = activity account eid name user stamp
      insertEvents connection [profile account "alice-profile" "identify" 2 "alice" "2026-06-30 00:00:00 UTC" [("plan", Aeson.String "pro")], profile account "bob-profile" "identify" 2 "bob" "2026-06-30 00:00:00 UTC" [("plan", Aeson.String "free")], row "entry" "page_view" "alice" "2026-07-01 00:00:00 UTC" & #sessionId ?~ SessionId "shared", row "exit" "page_view" "bob" "2026-07-01 00:00:10 UTC" & #sessionId ?~ SessionId "shared"]
      pro <- input "user:plan" Filter.FilterEq (Aeson.String "pro")
      free <- input "user:plan" Filter.FilterEq (Aeson.String "free")
      withPool $ \pool -> do
        let req = (request account) {Query.to = fromGregorian 2026 7 2, Query.filters = [pro]}
        sum . pointValues <$> metric (Query.runSessionMetric pool SessionCount req) `shouldReturn` 1
        sum . pointValues <$> metric (Query.runSessionMetric pool SessionBounceRate req) `shouldReturn` 0
        sum . pointValues <$> metric (Query.runSessionMetric pool SessionAverageDuration req) `shouldReturn` 10
        sum . pointValues <$> metric (Query.runSessionMetric pool SessionCount req {Query.filters = [free]}) `shouldReturn` 0
        sum . pointValues <$> metric (Query.runAcquisition defaultRegistry pool AcquisitionUsers req) `shouldReturn` 1
        insertEvents connection [profile account "alice-new-plan" "identify" 2 "alice" "2026-07-03 00:00:00 UTC" [("plan", Aeson.String "free")]]
        sum . pointValues <$> metric (Query.runSessionMetric pool SessionCount req) `shouldReturn` 0
        sum . pointValues <$> metric (Query.runSessionMetric pool SessionCount req {Query.filters = [free]}) `shouldReturn` 1

    it "retains exact cardinality and numeric ordering through a repeated-trait pivot at the result boundary" $ withClickHouse $ \connection -> do
      let seed offset count = command connection (fromString ("INSERT INTO analytics.events_raw(event_id,event_name,source,source_service,occurred_at,received_at,user_id,account_id,schema_version,governed_traits_valid,properties,context) SELECT concat('trait-',toString(number),'-',toString(kind)),if(kind=0,'identify','page_view'),'web','traits',toDateTime64('2026-07-01',3,'UTC'),toDateTime64('2026-07-01',3,'UTC'),concat('u',toString(number)),'trait-cap',if(kind=0,2,1),kind=0,if(kind=0,concat('{\"company_size\":',toString(number),'}'),'{}'),'{}' FROM numbers(" <> show offset <> "," <> show count <> ") ARRAY JOIN [0,1] AS kind"))
      seed (0 :: Int) (10000 :: Int)
      present <- either (fail . Text.unpack) pure (Filter.mkMetricFilter "user:company_size" Filter.FilterSet Nothing)
      withPool $ \pool -> do
        let req = (request "trait-cap") {Query.groupBy = Just ["user:company_size"], Query.filters = [present, present]}
        result <- builtin pool "events" req
        length (result ^. #points) `shouldBe` 10000
        pointValues result `shouldBe` replicate 10000 2
        take 2 [Map.lookup "user:company_size" (point ^. #group) | point <- result ^. #points] `shouldBe` [Just (Just "0"), Just (Just "1")]
        seed 10000 1
        metricDefinition <- maybe (fail "missing events") pure (builtinMetric "events")
        runEff (Query.run defaultRegistry pool metricDefinition req) `shouldReturn` Left Query.MetricResultTooLarge
      cfg <- clickHouseConfigFromConfig <$> requireConfig
      bracket (newQueryPoolWithLimits cfg 1 (MetricsQueryLimits 30 1)) closeQueryPool $ \pool -> do
        definition <- maybe (fail "missing events") pure (builtinMetric "events")
        runEff (Query.run defaultRegistry pool definition ((request "trait-cap") {Query.filters = [present]})) `shouldReturn` Left Query.QueryResourceLimit
  where
    now = read "2026-07-01 00:00:00 UTC"

request :: Text -> Query.QueryRequest
request account = Query.QueryRequest (AccountId account) (fromGregorian 2026 7 1) (fromGregorian 2026 7 3) Nothing Nothing [] False

activity :: Text -> Text -> Text -> Text -> String -> AnalyticsEvent
activity account eid name user stamp = baseEvent (EventId eid) (EventName name) Web (read stamp) (read stamp) & #accountId ?~ AccountId account & #userId ?~ UserId user & #sourceService ?~ "traits" & #url ?~ "https://example.com/entry"

profile :: Text -> Text -> Text -> Int -> Text -> String -> [(Aeson.Key, Aeson.Value)] -> AnalyticsEvent
profile account eid name version user stamp values = activity account eid name user stamp & #schemaVersion ?~ version & #properties .~ KM.fromList values

input :: Text -> Filter.FilterOp -> Aeson.Value -> IO Filter.MetricFilter
input name op value = either (fail . Text.unpack) pure (Filter.mkMetricFilter name op (Just value))

readValue :: BS.ByteString -> Aeson.Value
readValue = either error id . Aeson.eitherDecodeStrict'

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _ = False

withPool :: (QueryPool -> IO a) -> IO a
withPool action = do
  cfg <- clickHouseConfigFromConfig <$> requireConfig
  bracket (newQueryPool cfg 1) closeQueryPool action

metric :: Eff '[IOE] (Either Query.QueryExecutionError MetricResult) -> IO MetricResult
metric action = runEff action >>= either (fail . show) pure

builtin :: QueryPool -> Text -> Query.QueryRequest -> IO MetricResult
builtin pool name req = case builtinMetric name of
  Nothing -> fail "missing metric"
  Just builtin -> metric (Query.run defaultRegistry pool builtin req)

pointValues :: MetricResult -> [Double]
pointValues = map (view #value) . view #points

newtype JsonRow = JsonRow {value :: BS.ByteString}
  deriving stock (Generic)
  deriving anyclass (ClickHaskell '[Column "value" ChString])

jsonValues :: Connection -> Text -> IO [Aeson.Value]
jsonValues connection sql = do
  rows <- concat . reverse <$> select (unsafeMkSelect (const (Text.encodeUtf8Builder sql)) :: Select '[Column "value" ChString] JsonRow) connection pure
  traverse (\(JsonRow bytes) -> either fail pure (Aeson.eitherDecodeStrict' bytes)) rows

traitRows :: Connection -> Text -> Text -> IO [Aeson.Value]
traitRows connection account user = jsonValues connection ("SELECT toJSONString(tuple(name,trait_type,text_value,number_value)) AS value FROM analytics.user_traits WHERE account_id='" <> account <> "' AND user_id='" <> user <> "' ORDER BY name")
