{-# LANGUAGE OverloadedRecordDot #-}

-- | Atomic per-credential admission, using monotonic time and bounded state.
module Kansoku.Ingest.RateLimit
  ( RatePolicy (..),
    RateLimiter,
    newRateLimiter,
    newRateLimiterWithClock,
    admit,
    trackedCredentials,
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Clock (getMonotonicTime)
import Kansoku.Auth.Types (ApiKeyId, apiKeyIdText)

data RatePolicy = RatePolicy
  { eventsPerSecond :: !Int,
    burstSize :: !Int,
    maxCredentials :: !Int
  }
  deriving stock (Eq, Show)

data Bucket = Bucket
  { tokens :: !Double,
    updatedAt :: !Double,
    lastSeen :: !Double
  }

data RateLimiter
  = Disabled
  | Enabled !RatePolicy !(IO Double) !(MVar (Double, Map.Map Text Bucket))

newRateLimiter :: RatePolicy -> IO RateLimiter
newRateLimiter policy = newRateLimiterWithClock policy getMonotonicTime

newRateLimiterWithClock :: RatePolicy -> IO Double -> IO RateLimiter
newRateLimiterWithClock policy clock
  | policy.eventsPerSecond < 0 = fail "ingest rate must be nonnegative"
  | policy.eventsPerSecond == 0 = pure Disabled
  | policy.burstSize < 1 || policy.maxCredentials < 1 = fail "enabled ingest rate requires positive burst and bounded credential capacity"
  | otherwise = Enabled policy clock <$> newMVar (0, Map.empty)

-- | A denied request receives a positive, whole-second retry delay. Successful
-- admission charges every submitted event, including subsequent validation
-- failures. Denial never admits or partially charges a request.
admit :: RateLimiter -> ApiKeyId -> Int -> IO (Either Int ())
admit Disabled _ _ = pure (Right ())
admit _ _ 0 = pure (Right ())
admit (Enabled policy clock cell) key cost
  | cost < 0 = fail "ingest admission cost must be nonnegative"
  | otherwise = modifyMVar cell $ \(sweptAt, previous) -> do
      now <- clock
      let rate = fromIntegral policy.eventsPerSecond
          burst = fromIntegral policy.burstSize
          idleLifetime = max 60 (burst / rate)
          identity = apiKeyIdText key
          sweep = now - sweptAt >= 60 || (Map.notMember identity previous && Map.size previous >= policy.maxCredentials)
          buckets = if sweep then Map.filter (\bucket -> now - bucket.lastSeen < idleLifetime) previous else previous
          nextSweep = if sweep then now else sweptAt
          delay seconds = max 1 (ceiling seconds)
      case Map.lookup identity buckets of
        Nothing
          | Map.size buckets >= policy.maxCredentials ->
              let earliest = minimum [max 0 (idleLifetime - (now - bucket.lastSeen)) | bucket <- Map.elems buckets]
               in pure ((nextSweep, buckets), Left (delay earliest))
        existing -> do
          let old = maybe (Bucket burst now now) id existing
              current = max now old.updatedAt
              available = min burst (old.tokens + (current - old.updatedAt) * rate)
              allowed = available >= fromIntegral cost
              remaining = if allowed then available - fromIntegral cost else available
              bucket = Bucket remaining current (max now old.lastSeen)
              outcome = if allowed then Right () else Left (delay ((fromIntegral cost - available) / rate))
          pure ((nextSweep, Map.insert identity bucket buckets), outcome)

trackedCredentials :: RateLimiter -> IO Int
trackedCredentials Disabled = pure 0
trackedCredentials (Enabled _ _ cell) = Map.size . snd <$> readMVar cell
