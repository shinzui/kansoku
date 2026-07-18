module Kansoku.QuerySpec (spec) where

import Data.Text qualified as Text
import Data.Time (fromGregorian)
import Kansoku.Metrics.Api (TimeGrain (..))
import Kansoku.Metrics.Query
import Kansoku.Metrics.Registry
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Query.buildSQL" $ do
  it "reads active users at day grain from analytics.dau with uniqCombinedMerge" $
    buildSQL (Simple activeUsers) dayRequest
      `shouldBe` Text.unlines
        [ "SELECT toString(day) AS bucket, '' AS group_key,",
          "       toFloat64(uniqCombinedMerge(users)) AS value",
          "FROM analytics.dau",
          "WHERE day >= '2026-06-01' AND day < '2026-06-08'",
          "GROUP BY day",
          "ORDER BY day"
        ]

  it "reads page views at day grain from the count-state rollup" $
    buildSQL (Simple pageViews) dayRequest
      `shouldBe` Text.unlines
        [ "SELECT toString(day) AS bucket, '' AS group_key,",
          "       toFloat64(countMerge(views)) AS value",
          "FROM analytics.page_views_by_route",
          "WHERE day >= '2026-06-01' AND day < '2026-06-08'",
          "GROUP BY day",
          "ORDER BY day"
        ]

  it "counts events at day grain with distinct event ids" $
    buildSQL (Simple events) dayRequest
      `shouldBe` Text.unlines
        [ "SELECT toString(toDate(occurred_at)) AS bucket, '' AS group_key,",
          "       toFloat64(count(DISTINCT event_id)) AS value",
          "FROM analytics.events_raw",
          "WHERE occurred_at >= '2026-06-01 00:00:00' AND occurred_at < '2026-06-08 00:00:00'",
          "GROUP BY bucket, group_key",
          "ORDER BY bucket, group_key"
        ]

  it "builds conversion ratio SQL from identity-resolved users" $
    buildSQL (Ratioed conversionRate) dayRequest
      `shouldContainText` "if(denominator = 0, 0, numerator / denominator) AS value"

  it "counts sessions by distinct non-empty session ids" $
    buildSessionsSQL dayRequest
      `shouldBe` Text.unlines
        [ "SELECT toString(toDate(occurred_at)) AS bucket, '' AS group_key,",
          "       toFloat64(uniqExact(session_id)) AS value",
          "FROM analytics.events_raw",
          "WHERE occurred_at >= '2026-06-01 00:00:00' AND occurred_at < '2026-06-08 00:00:00'",
          "  AND session_id != ''",
          "GROUP BY bucket, group_key",
          "ORDER BY bucket, group_key"
        ]

  it "builds retention SQL with default offsets plus cohort size" $
    buildRetentionSQL dayRequest [1, 7, 14, 30]
      `shouldContainText` "WHERE dateDiff('day', f.cohort_day, a.active_day) IN (0,1,7,14,30)"

dayRequest :: QueryRequest
dayRequest =
  QueryRequest
    { from = fromGregorian 2026 6 1,
      to = fromGregorian 2026 6 8,
      groupBy = Nothing,
      timeGrain = Just Day
    }

shouldContainText :: Text -> Text -> Expectation
shouldContainText haystack needle =
  Text.isInfixOf needle haystack `shouldBe` True
