-- | Correct future-clock skew once, at the ingest boundary.
module Kansoku.Ingest.Timestamp
  ( TimestampAdjustment (..),
    normalizeOccurredAt,
  )
where

import Data.Generics.Labels ()
import Data.Time (NominalDiffTime, addUTCTime, diffUTCTime)
import Kansoku.Event.Types
import Kansoku.Prelude

data TimestampAdjustment = SkewCorrected | Clamped
  deriving stock (Eq, Show)

-- | Past occurrences are authoritative. A usable client send time preserves
-- elapsed time; otherwise only small future offsets can be clamped. Leaving a
-- large offset unchanged lets ordinary validation reject it. The send time is
-- consumed here and is never included in the queued event.
normalizeOccurredAt :: NominalDiffTime -> UTCTime -> AnalyticsEvent -> (AnalyticsEvent, Maybe TimestampAdjustment)
normalizeOccurredAt tolerance received event
  | occurred <= received = (clean, Nothing)
  | Just sent <- event ^. #sentAt,
    sent >= occurred =
      (clean & #occurredAt .~ addUTCTime (negate (diffUTCTime sent occurred)) received, Just SkewCorrected)
  | tolerance > 0,
    diffUTCTime occurred received <= tolerance =
      (clean & #occurredAt .~ received, Just Clamped)
  | otherwise = (clean, Nothing)
  where
    occurred = event ^. #occurredAt
    clean = event & #receivedAt .~ received & #sentAt .~ Nothing
