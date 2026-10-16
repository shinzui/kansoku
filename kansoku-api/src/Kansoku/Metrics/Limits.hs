-- | Fixed public limits for complete aggregate answers.
module Kansoku.Metrics.Limits
  ( maxQueryDays,
    maxFunnelSteps,
    maxRetentionDays,
    maxRetentionOffset,
    maxMetricPoints,
    maxPathSteps,
    maxPathTop,
    maxPathWindowSeconds,
    maxPathEvents,
  )
where

maxQueryDays :: Integer
maxQueryDays = 366

maxFunnelSteps, maxRetentionDays, maxRetentionOffset, maxMetricPoints :: Int
maxFunnelSteps = 20
maxRetentionDays = 32
maxRetentionOffset = 365
maxMetricPoints = 10000

maxPathSteps, maxPathTop, maxPathWindowSeconds, maxPathEvents :: Int
maxPathSteps = 10
maxPathTop = 20
maxPathWindowSeconds = 7776000
maxPathEvents = 100
