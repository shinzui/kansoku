module Kansoku.ReadinessSpec (spec) where

import Data.Int (Int64)
import Data.Time.Clock (addUTCTime)
import Kansoku.Observability (QueueDepthSample (..))
import Kansoku.Prelude
import Kansoku.Readiness
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Readiness.evaluatePipelineReadiness" $ do
  it "returns no pipeline failures without a queue sample" $
    evaluatePipelineReadiness thresholds startedAt Nothing Nothing now
      `shouldBe` []

  it "ignores stale samples even when the backlog is large" $
    evaluatePipelineReadiness thresholds startedAt (Just (sampleAt 1000 (addUTCTime (-31) now))) Nothing now
      `shouldBe` []

  it "fires queue depth only above the configured limit" $ do
    evaluatePipelineReadiness thresholds startedAt (Just (sampleAt 100 now)) (Just now) now
      `shouldBe` []
    evaluatePipelineReadiness thresholds startedAt (Just (sampleAt 101 now)) (Just now) now
      `shouldBe` [QueueDepthExceeded {observed = 101, limit = 100}]

  it "does not report flush staleness for an empty queue" $
    evaluatePipelineReadiness thresholds startedAt (Just (sampleAt 0 now)) Nothing now
      `shouldBe` []

  it "uses startup as the grace-period baseline before the first flush" $ do
    evaluatePipelineReadiness thresholds (addUTCTime (-30) now) (Just (sampleAt 1 now)) Nothing now
      `shouldBe` []
    evaluatePipelineReadiness thresholds startedAt (Just (sampleAt 1 now)) Nothing now
      `shouldBe` [neverFlushedFailure 1]

  it "accepts a recent last flush" $
    evaluatePipelineReadiness thresholds startedAt (Just (sampleAt 1 now)) (Just (addUTCTime (-10) now)) now
      `shouldBe` []

  it "returns depth and stale-flush failures together" $
    evaluatePipelineReadiness thresholds startedAt (Just (sampleAt 101 now)) Nothing now
      `shouldBe` [ QueueDepthExceeded {observed = 101, limit = 100},
                   neverFlushedFailure 101
                 ]

thresholds :: ReadyThresholds
thresholds =
  ReadyThresholds
    { maxQueueDepth = 100,
      maxFlushAgeSec = 60,
      sampleMaxAgeSec = 30
    }

now :: UTCTime
now = read "2026-07-19 12:02:00 UTC"

startedAt :: UTCTime
startedAt = addUTCTime (-120) now

sampleAt :: Int64 -> UTCTime -> QueueDepthSample
sampleAt depth timestamp =
  QueueDepthSample
    { sampleQueueLength = depth,
      sampleOldestAgeSec = Nothing,
      sampledAt = timestamp
    }

neverFlushedFailure :: Int64 -> ReadyCheckFailure
neverFlushedFailure depth =
  WriterFlushStale
    { lastFlushAt = Nothing,
      ageSeconds = 120,
      limitSeconds = 60,
      backlog = depth
    }
