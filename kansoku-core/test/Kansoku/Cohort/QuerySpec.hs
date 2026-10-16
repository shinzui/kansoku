module Kansoku.Cohort.QuerySpec (spec) where

import Data.Aeson qualified as A
import Data.Either (isLeft)
import Data.Text qualified as T
import Data.Time (fromGregorian)
import Kansoku.Cohort.Query
import Kansoku.Cohort.Types
import Kansoku.Event (AccountId (..), defaultRegistry)
import Kansoku.Metrics.Api (SessionMeasure (..))
import Kansoku.Metrics.Filter qualified as F
import Kansoku.Metrics.Query qualified as Q
import Kansoku.Metrics.Registry qualified as Registry
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Cohort compiler" $ do
  it "rejects invalid write definitions and undeclared properties" $ do
    validateCohort definition {conditions = replicate 5 condition} `shouldSatisfy` isLeft
    validateCohort definition {conditions = [condition {withinDays = 400}]} `shouldSatisfy` isLeft
    validateCohort definition {kind = "static"} `shouldSatisfy` isLeft
    bad <- either (fail . T.unpack) pure (F.mkMetricFilter "prop:missing" F.FilterEq (Just (A.String "x")))
    validateCohort definition {conditions = [condition {filters = [bad]}]} `shouldSatisfy` isLeft
  it "binds event names, frequency and original observation bounds in account-scoped subqueries" $ do
    membership <- either (fail . T.unpack) pure (compileMembership ident end definition)
    predicate membership `shouldSatisfy` T.isInfixOf "account_id={account_id:String}"
    predicate membership `shouldSatisfy` (not . T.isInfixOf "private_event")
    map snd (parameters membership) `shouldContain` ["private_event"]
    map snd (parameters membership) `shouldContain` ["2026-06-03"]
    map snd (parameters membership) `shouldContain` ["2026-07-03"]
  it "scopes static and current-trait relations as well as every behavioural source" $ do
    static <- either (fail . T.unpack) pure (compileMembership ident end (CohortDefinition "list" "static" [] []))
    predicate static `shouldSatisfy` T.isInfixOf "analytics.cohort_members WHERE account_id={account_id:String}"
    trait <- either (fail . T.unpack) pure (F.mkMetricFilter "user:plan" F.FilterEq (Just (A.String "pro")))
    member <- either (fail . T.unpack) pure (compileMembership ident end definition {traits = [trait]})
    predicate member `shouldSatisfy` T.isInfixOf "analytics.user_traits WHERE account_id={account_id:String}"
    T.count "events_resolved_http(" (predicate member) `shouldBe` T.count "scope_account={account_id:String}" (predicate member)
  it "forces resolved event and whole-session paths, with matching cohort groups" $ do
    membership <- either (fail . T.unpack) pure (compileMembership ident end definition)
    selected <- either (fail . T.unpack) pure (F.mkMetricFilter "cohort" F.FilterEq (Just (A.String ident)))
    let request = Q.QueryRequest (AccountId "cohort-sentinel") (fromGregorian 2026 7 1) end (Just ["cohort:" <> ident]) Nothing [selected] [(ident, membership)] False False False
    users <- either (fail . show) pure (Q.buildSQL defaultRegistry (Registry.Simple Registry.activeUsers) request)
    users `shouldSatisfy` T.isInfixOf "events_resolved_http"
    users `shouldSatisfy` T.isInfixOf "'in', 'out'"
    sessions <- either (fail . show) pure (Q.buildSessionMetricSQL SessionCount request)
    sessions `shouldSatisfy` T.isInfixOf "primary_subject IN"
    sessions `shouldSatisfy` T.isInfixOf "GROUP BY account_id,source_service,session_id"
  it "retains zero-count users in upper-bound criteria and complements didNot" $ do
    upper <- either (fail . T.unpack) pure (compileMembership ident end definition {conditions = [condition {atLeast = Nothing, atMost = Just 1}]})
    predicate upper `shouldSatisfy` T.isInfixOf "canonical_user NOT IN"
    negative <- either (fail . T.unpack) pure (compileMembership ident end definition {conditions = [condition {did = Nothing, didNot = Just "cancelled"}]})
    predicate negative `shouldSatisfy` T.isInfixOf "NOT (canonical_user IN"
  where
    ident = "eb0aa865-9092-41b1-8c6d-8febd3192ae1"
    end = fromGregorian 2026 7 3
    condition = CohortCondition (Just "private_event") Nothing (Just 3) Nothing 30 []
    definition = CohortDefinition "power" "behavioural" [condition] []
