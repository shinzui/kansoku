module Kansoku.Ingest.RateLimitSpec (spec) where

import Control.Concurrent.Async (mapConcurrently)
import Data.Either (isRight)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.UUID qualified as UUID
import Kansoku.Auth.Types (ApiKeyId (..))
import Kansoku.Ingest.RateLimit
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Ingest.RateLimit" $ do
  it "charges event counts atomically and returns whole-second refill delays per credential" $ do
    clock <- newIORef 0
    limiter <- newRateLimiterWithClock (RatePolicy 2 4 2) (readIORef clock)
    admit limiter a 3 `shouldReturn` Right ()
    admit limiter a 2 `shouldReturn` Left 1
    writeIORef clock 0.499
    admit limiter a 2 `shouldReturn` Left 1
    writeIORef clock 0.5
    admit limiter a 2 `shouldReturn` Right ()
    admit limiter b 4 `shouldReturn` Right ()
    writeIORef clock 1
    admit limiter a 1 `shouldReturn` Right ()

  it "permits only one burst across concurrent requests" $ do
    limiter <- newRateLimiterWithClock (RatePolicy 1 10 2) (pure 0)
    results <- mapConcurrently (\_ -> admit limiter a 1) [1 .. 100 :: Int]
    length (filter isRight results) `shouldBe` 10
    trackedCredentials limiter `shouldReturn` 1

  it "evicts only fully refilled idle buckets and bounds tracked credentials" $ do
    clock <- newIORef 0
    limiter <- newRateLimiterWithClock (RatePolicy 1 100 1) (readIORef clock)
    admit limiter a 100 `shouldReturn` Right ()
    writeIORef clock 60
    admit limiter b 1 `shouldReturn` Left 40
    trackedCredentials limiter `shouldReturn` 1
    writeIORef clock 99.9
    admit limiter b 1 `shouldReturn` Left 1
    writeIORef clock 100
    admit limiter b 100 `shouldReturn` Right ()
    trackedCredentials limiter `shouldReturn` 1

  it "does not refill from a backward observation or allocate state when disabled/empty" $ do
    clock <- newIORef 10
    limiter <- newRateLimiterWithClock (RatePolicy 1 2 1) (readIORef clock)
    admit limiter a 2 `shouldReturn` Right ()
    writeIORef clock 9
    admit limiter a 1 `shouldReturn` Left 1
    writeIORef clock 10.5
    admit limiter a 1 `shouldReturn` Left 1
    writeIORef clock 11
    admit limiter a 1 `shouldReturn` Right ()
    disabled <- newRateLimiter (RatePolicy 0 0 0)
    admit disabled (error "disabled admission must not inspect credentials") 10000 `shouldReturn` Right ()
    trackedCredentials disabled `shouldReturn` 0
    empty <- newRateLimiter (RatePolicy 1 1 1)
    admit empty a 0 `shouldReturn` Right ()
    trackedCredentials empty `shouldReturn` 0
  where
    a = ApiKeyId UUID.nil
    b = ApiKeyId (UUID.fromWords 0 0 0 1)
