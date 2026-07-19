-- | Pure readiness threshold evaluation for the pipeline checks EP-16 adds on
-- top of EP-10's writer-liveness and pgmq-reachability checks.
module Kansoku.Readiness
  ( ReadyThresholds (..),
    ReadyCheckFailure (..),
    checkName,
    evaluatePipelineReadiness,
  )
where

import Data.Int (Int64)
import Data.Time.Clock (diffUTCTime)
import Kansoku.Observability (QueueDepthSample (..))
import Kansoku.Prelude

data ReadyThresholds = ReadyThresholds
  { maxQueueDepth :: !Int64,
    maxFlushAgeSec :: !Int,
    sampleMaxAgeSec :: !Int
  }
  deriving stock (Generic, Eq, Show)

data ReadyCheckFailure
  = QueueDepthExceeded
      { observed :: !Int64,
        limit :: !Int64
      }
  | WriterFlushStale
      { lastFlushAt :: !(Maybe UTCTime),
        ageSeconds :: !Int,
        limitSeconds :: !Int,
        backlog :: !Int64
      }
  deriving stock (Generic, Eq, Show)

checkName :: ReadyCheckFailure -> Text
checkName = \case
  QueueDepthExceeded {} -> "queue_depth"
  WriterFlushStale {} -> "writer_flush_stale"

-- | Evaluate pipeline checks against the latest fresh queue sample. Missing or
-- stale samples disable these checks; EP-10's pgmq check owns that dependency.
evaluatePipelineReadiness ::
  ReadyThresholds ->
  UTCTime ->
  Maybe QueueDepthSample ->
  Maybe UTCTime ->
  UTCTime ->
  [ReadyCheckFailure]
evaluatePipelineReadiness thresholds startedAt maybeSample lastFlush now =
  case freshSample of
    Nothing -> []
    Just sample -> depthFailure sample <> flushFailure sample
  where
    freshSample = do
      sample <- maybeSample
      guard (ageSec (sample ^. #sampledAt) <= thresholds ^. #sampleMaxAgeSec)
      pure sample

    depthFailure sample =
      [ QueueDepthExceeded
          { observed = sample ^. #sampleQueueLength,
            limit = thresholds ^. #maxQueueDepth
          }
      | sample ^. #sampleQueueLength > thresholds ^. #maxQueueDepth
      ]

    flushFailure sample =
      let baseline = fromMaybe startedAt lastFlush
          age = ageSec baseline
       in [ WriterFlushStale
              { lastFlushAt = lastFlush,
                ageSeconds = age,
                limitSeconds = thresholds ^. #maxFlushAgeSec,
                backlog = sample ^. #sampleQueueLength
              }
          | sample ^. #sampleQueueLength > 0,
            age > thresholds ^. #maxFlushAgeSec
          ]

    ageSec timestamp = floor (diffUTCTime now timestamp)
