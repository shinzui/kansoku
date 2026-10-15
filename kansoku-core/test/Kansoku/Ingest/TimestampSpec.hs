module Kansoku.Ingest.TimestampSpec (spec) where

import Data.Generics.Labels ()
import Data.Time (addUTCTime)
import Kansoku.Event
import Kansoku.Ingest.Timestamp
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Ingest.Timestamp" $ do
  it "uses send-time elapsed duration only for future occurrences" $ do
    corrected 90 (Just 90) `shouldBe` (at 0, Just SkewCorrected)
    corrected 90 (Just 100) `shouldBe` (at (-10), Just SkewCorrected)
    corrected (-90) (Just 100) `shouldBe` (at (-90), Nothing)
  it "falls back to tolerance when send time is absent or precedes occurrence" $ do
    corrected 90 Nothing `shouldBe` (at 0, Just Clamped)
    corrected 90 (Just 80) `shouldBe` (at 0, Just Clamped)
    corrected 86401 Nothing `shouldBe` (at 86401, Nothing)
  it "allows disabling clamping without disabling valid send-time correction" $ do
    normalizeOccurredAt 0 now (at 90) `shouldBe` (at 90, Nothing)
    normalizeOccurredAt 0 now (at 90 & #sentAt ?~ addUTCTime 100 now)
      `shouldBe` (at (-10), Just SkewCorrected)
  it "rejects dates outside the supported storage range after correction" $ do
    let (ancient, _) = normalizeOccurredAt 86400 now (at 90 & #sentAt ?~ read "9999-01-01 00:00:00 UTC")
    validateEvent ancient `shouldSatisfy` isLeft
    validateEvent (at 0 & #occurredAt .~ read "1969-12-31 23:59:59 UTC") `shouldSatisfy` isLeft
  where
    corrected offset sent = normalizeOccurredAt 86400 now (at offset & #sentAt .~ fmap (`addUTCTime` now) sent)
    at offset = baseEvent (EventId "timestamp") (EventName "custom") Web (addUTCTime offset now) now
    now = read "2026-10-15 12:00:00 UTC"
    isLeft (Left _) = True
    isLeft _ = False
