module Kansoku.Users.HandlerSpec (spec) where

import Control.Monad (forM_)
import Kansoku.Metrics.Filter (parseMetricFilter)
import Kansoku.Prelude
import Kansoku.Users.Validation
import Test.Hspec

spec :: Spec
spec = describe "Users request bounds" $ do
  it "requires paired bounded dates" $ do
    validateDates (Just (read "2026-01-01")) Nothing `shouldSatisfy` isLeft
    validateDates (Just (read "2024-01-01")) (Just (read "2026-01-01")) `shouldSatisfy` isLeft
  it "rejects empty searches and unknown orders" $ do
    validateDirectory Nothing Nothing (Just "") Nothing [] `shouldSatisfy` isLeft
    validateDirectory Nothing Nothing Nothing (Just "other") [] `shouldSatisfy` isLeft
  it "rejects event dimensions and incorrectly typed traits" $ do
    forM_ ["event_name:eq:identify", "user:company_size:eq:large", "{\"or\":[{\"dimension\":\"user:plan\",\"op\":\"eq\",\"value\":\"pro\"}]}"] $ \raw -> case parseMetricFilter raw of
      Left _ -> pure ()
      Right f -> validateDirectory Nothing Nothing Nothing Nothing [f] `shouldSatisfy` isLeft
  where
    isLeft (Left _) = True; isLeft _ = False
