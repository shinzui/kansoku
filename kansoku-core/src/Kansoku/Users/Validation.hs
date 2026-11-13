module Kansoku.Users.Validation where

import Control.Monad (forM_)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.Text qualified as T
import Data.Time (Day)
import Data.UUID qualified as UUID
import Kansoku.Event (defaultRegistry)
import Kansoku.Metrics.Filter qualified as F
import Kansoku.Metrics.Query.Filter qualified as QF
import Kansoku.Metrics.Query.Validate (QueryLimitError (..), mkSqlName, validateDateRange)
import Kansoku.Prelude

validateDates :: Maybe Day -> Maybe Day -> Either Text ()
validateDates Nothing Nothing = Right ()
validateDates (Just lo) (Just hi) = case validateDateRange lo hi of
  Left (QueryLimitError _ message) -> Left message
  Right () -> Right ()
validateDates _ _ = Left "from and to must be supplied together"

validateDirectory :: Maybe Day -> Maybe Day -> Maybe Text -> Maybe Text -> [F.MetricFilter] -> Either Text ()
validateDirectory lo hi search order filters = do
  validateDates lo hi
  unless (maybe True (\s -> T.length s >= 1 && T.length s <= 256) search) (Left "search must contain 1..256 Unicode code points")
  unless (fromMaybe "lastActivity" order `elem` ["lastActivity", "firstActivity"]) (Left "unsupported user order")
  unless (all atomic filters) (Left "OR filters are not supported")
  let users = filter (T.isPrefixOf "user:" . F.dimension) filters
      cohorts = filter ((== "cohort") . F.dimension) filters
  unless (length users <= 8 && length cohorts <= 1 && length filters == length users + length cohorts) (Left "only eight user traits and one cohort filter are supported")
  void (QF.compileMetricFilters defaultRegistry [] users)
  forM_ cohorts $ \f -> case (F.op f, F.value f) of
    (op, Just (A.String value)) | op `elem` [F.FilterEq, F.FilterNeq], isJust (UUID.fromText value) -> Right ()
    _ -> Left "cohort requires eq/neq and a UUID"

validateHistory :: [F.MetricFilter] -> Either Text ()
validateHistory filters = do
  unless (length filters <= 1 && all atomic filters) (Left "history accepts one event-name predicate")
  mapM_ check filters
  where
    check f = do
      unless (F.dimension f == "event_name" && F.op f `elem` [F.FilterEq, F.FilterIn]) (Left "history requires event_name eq/in")
      let names = case F.value f of Just (A.String value) -> [A.String value]; Just (A.Array values) -> toList values; _ -> []
      unless (length names >= 1 && length names <= 100) (Left "event names require 1..100 values")
      mapM_
        ( \case
            A.String value -> case mkSqlName value of
              Left _ -> Left "invalid event name"
              Right _ -> Right ()
            _ -> Left "event names must be strings"
        )
        names

-- A one-term OR group is still outside the users grammar.
atomic :: F.MetricFilter -> Bool
atomic term = case A.toJSON term of
  A.Object object -> not (KM.member "or" object)
  _ -> False
