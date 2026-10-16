-- | Built-in semantic metrics for the MVP.
module Kansoku.Metrics.Registry
  ( BuiltinMetric (..),
    activeUsers,
    builtinMetric,
    builtinMetrics,
    conversionRate,
    events,
    pageViews,
    sessions,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Kansoku.Metrics.Api (TimeGrain (..))
import Kansoku.Metrics.Definition
import Kansoku.Prelude

data BuiltinMetric = Simple !MetricDefinition | Ratioed !RatioMetric
  deriving stock (Generic, Eq, Show)

builtinMetric :: Text -> Maybe BuiltinMetric
builtinMetric key = Map.lookup key builtinMetrics

builtinMetrics :: Map Text BuiltinMetric
builtinMetrics =
  Map.fromList
    [ ("events", Simple events),
      ("page_views", Simple pageViews),
      ("sessions", Simple sessions),
      ("active_users", Simple activeUsers),
      ("organizations", Simple (metric "organizations" "Exact organizations active in each bucket." [] UniqueCount [] (Just Day))),
      ("new_users", Simple newUsers),
      ("returning_users", Simple returningUsers),
      ("conversion_rate", Ratioed conversionRate),
      ("activation_rate", Ratioed activationRate),
      ("retention", Ratioed retention),
      ("feature_adoption", Simple featureAdoption),
      ("revenue", Simple revenue),
      ("search_success_rate", Ratioed searchSuccessRate),
      ("funnel_completion_rate", Ratioed funnelCompletionRate)
    ]

events :: MetricDefinition
events =
  metric "events" "Distinct ingested events." [] Count [] (Just Day)

pageViews :: MetricDefinition
pageViews =
  metric "page_views" "Distinct canonical page-view events with consistent filters at every grain." ["page_view"] Count [] (Just Day)

sessions :: MetricDefinition
sessions =
  metric "sessions" "Whole retained web sessions keyed by account, source service and session ID; assigned to their earliest event bucket." [] UniqueCount [] (Just Day)

activeUsers :: MetricDefinition
activeUsers =
  metric "active_users" "Exact resolved active identities, excluding identity-only profile events." [] UniqueCount [] (Just Day)

newUsers :: MetricDefinition
newUsers =
  metric "new_users" "Distinct users who registered or created an account." ["user_registered", "account_created"] UniqueCount [] (Just Day)

returningUsers :: MetricDefinition
returningUsers =
  metric "returning_users" "Distinct active users who were first seen before the requested bucket." [] UniqueCount [] (Just Day)

featureAdoption :: MetricDefinition
featureAdoption =
  metric "feature_adoption" "Distinct users who used a tracked feature." ["feature_used"] UniqueCount ["prop:feature"] (Just Day)

revenue :: MetricDefinition
revenue =
  (metric "revenue" "Revenue summed from payment event amount properties." ["payment_completed"] Sum [] (Just Day))
    { aggregationProperty = Just "amount"
    }

conversionRate :: RatioMetric
conversionRate =
  RatioMetric
    { name = "conversion_rate",
      description = Just "Unique users completing signup divided by users starting signup.",
      numerator = metric "signup_completed_users" "Users who completed signup." ["signup_completed"] UniqueCount [] Nothing,
      denominator = metric "signup_started_users" "Users who started signup." ["signup_started"] UniqueCount [] Nothing
    }

activationRate :: RatioMetric
activationRate =
  RatioMetric
    { name = "activation_rate",
      description = Just "Users completing onboarding divided by users creating an account.",
      numerator = metric "onboarding_completed_users" "Users who completed onboarding." ["onboarding_completed"] UniqueCount [] Nothing,
      denominator = metric "account_created_users" "Users who created an account." ["account_created"] UniqueCount [] Nothing
    }

retention :: RatioMetric
retention =
  RatioMetric
    { name = "retention",
      description = Just "Users returning after their first-seen cohort day divided by cohort size.",
      numerator = metric "retained_users" "Users active again after cohort day." [] UniqueCount [] Nothing,
      denominator = metric "cohort_users" "Users in the cohort." [] UniqueCount [] Nothing
    }

searchSuccessRate :: RatioMetric
searchSuccessRate =
  RatioMetric
    { name = "search_success_rate",
      description = Just "Searches with results divided by all searches.",
      numerator = metric "searches_with_results" "Searches that returned results." ["search_performed"] Count [] Nothing,
      denominator = metric "searches" "All performed searches." ["search_performed"] Count [] Nothing
    }

funnelCompletionRate :: RatioMetric
funnelCompletionRate =
  RatioMetric
    { name = "funnel_completion_rate",
      description = Just "Users reaching the final funnel step divided by users reaching the first step.",
      numerator = metric "funnel_completed_users" "Users reaching the final funnel step." ["signup_completed"] UniqueCount [] Nothing,
      denominator = metric "funnel_started_users" "Users reaching the first funnel step." ["signup_started"] UniqueCount [] Nothing
    }

metric :: Text -> Text -> [Text] -> Aggregation -> [Text] -> Maybe TimeGrain -> MetricDefinition
metric name description eventNames aggregation groupBy timeGrain =
  MetricDefinition
    { name,
      description = Just description,
      eventNames,
      aggregation,
      aggregationProperty = Nothing,
      filters = [],
      groupBy,
      timeGrain
    }
