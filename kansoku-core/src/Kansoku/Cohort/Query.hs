-- | Parameterised membership predicates. Negative conditions complement the
-- matching set, so users with zero matching occurrences remain eligible.
module Kansoku.Cohort.Query where

import Data.Text qualified as T
import Data.Time (Day, addDays)
import Data.UUID qualified as UUID
import Kansoku.Cohort.Types
import Kansoku.Event (EventName (..), defaultRegistry)
import Kansoku.Metrics.Filter qualified as F
import Kansoku.Metrics.Query.Filter qualified as Filters
import Kansoku.Metrics.Query.Traits qualified as Traits
import Kansoku.Prelude hiding (index)

data Membership = Membership {predicate :: !Text, parameters :: ![(String, Text)], since :: !Day}
  deriving stock (Generic, Eq, Show)

validateCohort :: CohortDefinition -> Either Text ()
validateCohort def = do
  validateDefinition def
  mapM_
    ( \c -> do
        unless (all (not . T.isPrefixOf "user:" . F.dimension) (concatMap F.filterTerms (filters c))) (Left "user: conditions belong in traits")
        void (Filters.compileMetricFilters defaultRegistry [EventName (fromMaybe "" (did c <|> didNot c))] (filters c))
    )
    (conditions def)
  unless (all (T.isPrefixOf "user:" . F.dimension) (concatMap F.filterTerms (traits def))) (Left "traits require governed user: dimensions")
  void (Filters.compileMetricFilters defaultRegistry [] (traits def))

compileMembership :: Text -> Day -> CohortDefinition -> Either Text Membership
compileMembership ident toDay def = do
  validateCohort def
  uuid <- maybe (Left "invalid cohort id") Right (UUID.fromText ident)
  let prefix = "cohort_" <> T.unpack (T.filter (/= '-') (UUID.toText uuid))
      key suffix = prefix <> suffix
      bind suffix value = (key suffix, value)
      param suffix = "{" <> T.pack (key suffix) <> ":String}"
      cohortSince = if null (traits def) then addDays (negate (fromIntegral (maximum (1 : map withinDays (conditions def))))) toDay else read "1970-01-01"
  if kind def == "static"
    then
      pure (Membership ("canonical_user IN (SELECT concat('user:',user_id) FROM analytics.cohort_members WHERE account_id={account_id:String} AND cohort_id=" <> param "_id" <> " GROUP BY user_id HAVING argMax(present,version)=1)") [bind "_id" (UUID.toText uuid)] cohortSince)
    else do
      compiled <- traverse (compileCondition prefix toDay) (zip [1 :: Int ..] (conditions def))
      traitFilters <- Filters.compileMetricFiltersWithPrefix (key "_trait") defaultRegistry [] (traits def)
      let traitSource = Traits.eventSource (Traits.referencedTraits (map F.dimension (concatMap F.filterTerms (traits def)))) (source (param "_universe_from") (param "_to"))
          traitPredicate = ["canonical_user IN (SELECT canonical_user FROM " <> traitSource <> " WHERE account_id={account_id:String} AND canonical_user!='' AND " <> T.intercalate " AND " (Filters.predicates traitFilters) <> ")" | not (null (traits def))]
      pure (Membership ("(startsWith(canonical_user,'user:') AND " <> T.intercalate " AND " (map fst compiled <> traitPredicate) <> ")") (concatMap snd compiled <> Filters.parameters traitFilters <> [bind "_universe_from" "1970-01-01", bind "_to" (T.pack (show toDay))]) cohortSince)

source :: Text -> Text -> Text
source fromParam toParam = "analytics.events_resolved_http(scope_all_accounts=0,scope_account={account_id:String},scope_from=toDateTime64(" <> fromParam <> ",3,'UTC'),scope_to=toDateTime64(" <> toParam <> ",3,'UTC'))"

compileCondition :: String -> Day -> (Int, CohortCondition) -> Either Text (Text, [(String, Text)])
compileCondition prefix toDay (index, c) = do
  let name = fromMaybe "" (did c <|> didNot c)
      key suffix = prefix <> "_" <> show index <> suffix
      param suffix = "{" <> T.pack (key suffix) <> ":String}"
      bindings = [(key "_event", name), (key "_from", T.pack (show (addDays (negate (fromIntegral (withinDays c))) toDay))), (key "_to", T.pack (show toDay)), (key "_min", T.pack (show (fromMaybe (if isJust (atMost c) then 0 else 1) (atLeast c)))), (key "_max", T.pack (show (fromMaybe (maxBound :: Int) (atMost c))))]
  compiled <- Filters.compileMetricFiltersWithPrefix (key "_filter") defaultRegistry [EventName name] (filters c)
  let population = source (param "_from") (param "_to")
      -- Include zero-count users when atLeast=0 or atMost alone is specified.
      counts = "SELECT canonical_user,uniqExact(event_id) AS n FROM " <> population <> " WHERE account_id={account_id:String} AND canonical_user!='' AND event_name=" <> param "_event" <> concatPredicates (Filters.predicates compiled) <> " GROUP BY canonical_user"
      positive = "canonical_user IN (SELECT canonical_user FROM (" <> counts <> ") WHERE n>=toUInt64(" <> param "_min" <> ") AND n<=toUInt64(" <> param "_max" <> "))"
      zeroEligible = fromMaybe (if isJust (atMost c) then 0 else 1) (atLeast c) == 0
      test = if zeroEligible then "(canonical_user NOT IN (SELECT canonical_user FROM (" <> counts <> ")) OR " <> positive <> ")" else positive
  pure ((if isJust (didNot c) then "NOT (" <> test <> ")" else test), bindings <> Filters.parameters compiled)

concatPredicates :: [Text] -> Text
concatPredicates = T.concat . map (" AND " <>)
