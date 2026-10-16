-- | Saved cohort definitions and management payloads.
module Kansoku.Cohort.Types where

import Data.Aeson qualified as A
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Data.UUID (UUID)
import Kansoku.Metrics.Filter (MetricFilter)
import Kansoku.Prelude

data CohortCondition = CohortCondition
  {did :: !(Maybe Text), didNot :: !(Maybe Text), atLeast :: !(Maybe Int), atMost :: !(Maybe Int), withinDays :: !Int, filters :: ![MetricFilter]}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON CohortCondition where
  parseJSON = A.withObject "cohort condition" $ \o ->
    CohortCondition
      <$> o A..:? "did"
      <*> o A..:? "didNot"
      <*> o A..:? "atLeast"
      <*> o A..:? "atMost"
      <*> o A..: "withinDays"
      <*> o A..:? "filters" A..!= []

data CohortDefinition = CohortDefinition
  {name :: !Text, kind :: !Text, conditions :: ![CohortCondition], traits :: ![MetricFilter]}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON CohortDefinition where
  parseJSON = A.withObject "cohort definition" $ \o ->
    CohortDefinition
      <$> o A..: "name"
      <*> o A..: "kind"
      <*> o A..:? "conditions" A..!= []
      <*> o A..:? "traits" A..!= []

data Cohort = Cohort {id :: !UUID, definition :: !CohortDefinition, createdAt :: !UTCTime, updatedAt :: !UTCTime}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON, FromJSON)

newtype CohortMembers = CohortMembers {userIds :: [Text]}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON, FromJSON)

newtype CohortSize = CohortSize {size :: Integer}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON, FromJSON)

validateDefinition :: CohortDefinition -> Either Text ()
validateDefinition CohortDefinition {name, kind, conditions, traits} = do
  require (not (T.null (T.strip name)) && T.length name <= 200) "name must contain 1..200 characters"
  require (kind `elem` ["behavioural", "static"]) "kind must be behavioural or static"
  require (length conditions <= 4) "at most four conditions are supported"
  require (if kind == "static" then null conditions && null traits else not (null conditions && null traits)) "static cohorts have no conditions; behavioural cohorts require conditions or traits"
  mapM_ condition conditions
  where
    require True _ = Right ()
    require False message = Left message
    condition CohortCondition {did, didNot, atLeast, atMost, withinDays} = do
      require ((isJust did /= isJust didNot) && all (not . T.null) (catMaybes [did, didNot])) "exactly one of did or didNot is required"
      require (withinDays >= 1 && withinDays <= 365) "withinDays must be in 1..365"
      require (all (>= 0) (catMaybes [atLeast, atMost]) && maybe True (\lo -> maybe True (>= lo) atMost) atLeast) "occurrence bounds must be nonnegative and ordered"
