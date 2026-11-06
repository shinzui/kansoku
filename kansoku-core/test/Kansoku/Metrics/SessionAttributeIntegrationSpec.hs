module Kansoku.Metrics.SessionAttributeIntegrationSpec (spec) where

import Control.Exception (bracket)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (fromGregorian)
import Effectful (runEff)
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Event
import Kansoku.Ingest.QueuedEvent (QueuedEvent, enrichedQueuedEvent)
import Kansoku.Ingest.RequestContext (IngestRequestContext (..))
import Kansoku.Metrics.Api (MetricResult, TimeGrain (..))
import Kansoku.Metrics.Filter qualified as Filter
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Registry (BuiltinMetric (..), pageViews)
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Session attributes native" $ do
  it "selects every page in a visit, groups route/referrer, and deduplicates replay" $ withClickHouse $ \connection -> do
    insertQueuedEvents connection rows
    withPool $ \pool -> do
      selected <- selectedRequest "session:channel:eq:organic_search"
      landing <- selectedRequest "channel:eq:organic_search"
      amount <$> pages pool selected `shouldReturn` 3
      amount <$> pages pool landing `shouldReturn` 1
      let req = request {Query.groupBy = Just ["route", "session:referrer_host"]}
      result <- pages pool req
      [(p ^. #group, p ^. #value) | p <- result ^. #points]
        `shouldMatchList` [(Map.fromList [("route", Just route), ("session:referrer_host", Just host)], 1) | (host, routes) <- [("www.google.com", ["/landing", "/pricing", "/checkout"]), ("news.ycombinator.com", ["/landing", "/pricing"])], route <- routes]
      insertQueuedEvents connection (reverse rows)
      mapM_ (insertQueuedEvents connection . pure) rows
      pages pool req `shouldReturn` result
      amount <$> pages pool selected `shouldReturn` 3

request :: Query.QueryRequest
request = Query.QueryRequest (AccountId "session-attributes-native") (fromGregorian 2026 7 1) (fromGregorian 2026 7 2) Nothing (Just Day) [] [] False False False

selectedRequest :: Text -> IO Query.QueryRequest
selectedRequest text = do
  input <- either (fail . Text.unpack) pure (Filter.parseMetricFilter text)
  pure request {Query.filters = [input]}

pages :: QueryPool -> Query.QueryRequest -> IO MetricResult
pages pool req = runEff (Query.run defaultRegistry pool (Simple pageViews) req) >>= either (fail . show) pure

amount :: MetricResult -> Double
amount result = sum [point ^. #value | point <- result ^. #points]

withPool :: (QueryPool -> IO a) -> IO a
withPool action = do
  cfg <- clickHouseConfigFromConfig <$> requireConfig
  bracket (newQueryPool cfg 1) closeQueryPool action

make :: Text -> Text -> String -> Text -> QueuedEvent
make eid sid timestamp route =
  enrichedQueuedEvent (IngestRequestContext Nothing (Just "GB")) $
    baseEvent (EventId eid) (EventName "page_view") Web (read timestamp) (read timestamp)
      & #accountId
      ?~ AccountId "session-attributes-native"
      & #sourceService
      ?~ "session-attributes-web"
      & #sessionId
      ?~ SessionId sid
      & #userId
      ?~ UserId sid
      & #url
      ?~ ("https://shop.example" <> route)

rows :: [QueuedEvent]
rows =
  [ make "a-landing" "a" "2026-07-01 12:00:00 UTC" "/landing" & #event . #referrer ?~ "https://www.google.com/search" & #event . #utmCampaign ?~ "launch" & #enrichment . #channel .~ "organic_search",
    make "a-pricing" "a" "2026-07-01 12:01:00 UTC" "/pricing" & #event . #referrer ?~ "https://shop.example/landing",
    make "a-checkout" "a" "2026-07-01 12:02:00 UTC" "/checkout" & #event . #referrer ?~ "https://shop.example/pricing",
    make "b-landing" "b" "2026-07-01 13:00:00 UTC" "/landing" & #event . #referrer ?~ "https://news.ycombinator.com/" & #enrichment . #channel .~ "referral",
    make "b-pricing" "b" "2026-07-01 13:01:00 UTC" "/pricing" & #event . #referrer ?~ "https://shop.example/landing"
  ]
