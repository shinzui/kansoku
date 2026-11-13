module Kansoku.Users.QuerySpec (spec) where

import Data.Aeson qualified as A
import Data.Map.Strict qualified as Map
import Kansoku.Event (defaultRegistry)
import Kansoku.Prelude
import Kansoku.Users.History (safeProperties)
import Kansoku.Users.Query
import Relay.Pagination.Hasql qualified as R
import Test.Hspec

spec :: Spec
spec = describe "Users complete cursor keys" $ do
  it "uses different cursor fingerprints for the two directory orders" $
    R.sortSpecFingerprint (summarySort "firstActivity") `shouldNotBe` R.sortSpecFingerprint (summarySort "lastActivity")
  it "retains zero and empty governed values while excluding unknown traits" $
    Map.keys (traitMap [("plan", "string", "", 0), ("company_size", "number", "", 0), ("secret", "string", "sentinel", 0)]) `shouldBe` ["company_size", "plan"]

  it "projects exact schema versions and excludes declared identity payloads" $ do
    let raw = A.object ["plan" A..= ("pro" :: Text), "secret" A..= ("hidden" :: Text), "previousId" A..= ("cookie" :: Text), "newId" A..= ("person" :: Text)]
    safeProperties defaultRegistry "identify" 1 raw `shouldBe` Map.empty
    Map.keys (safeProperties defaultRegistry "identify" 2 raw) `shouldBe` ["plan"]
    safeProperties defaultRegistry "alias" 1 raw `shouldBe` Map.empty
    safeProperties defaultRegistry "identify" 99 raw `shouldBe` Map.empty
  it "omits incompatible and non-scalar declared values" $ do
    safeProperties defaultRegistry "identify" 2 (A.object ["plan" A..= A.Null, "company_size" A..= ("wrong" :: Text)]) `shouldBe` Map.empty
