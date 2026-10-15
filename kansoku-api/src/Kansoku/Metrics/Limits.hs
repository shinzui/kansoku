-- | Fixed public limits for complete aggregate answers.
module Kansoku.Metrics.Limits
  ( maxQueryDays,
    maxFunnelSteps,
    maxRetentionDays,
    maxRetentionOffset,
    maxMetricPoints,
  )
where

maxQueryDays :: Integer
maxQueryDays = 366

maxFunnelSteps, maxRetentionDays, maxRetentionOffset, maxMetricPoints :: Int
maxFunnelSteps = 20
maxRetentionDays = 32
maxRetentionOffset = 365
maxMetricPoints = 10000
