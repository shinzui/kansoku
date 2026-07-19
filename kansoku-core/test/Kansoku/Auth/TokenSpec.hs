module Kansoku.Auth.TokenSpec (spec) where

import Data.Char (isDigit, isLower)
import Data.Text qualified as Text
import Kansoku.Auth.Token
import Kansoku.Auth.Types (CredentialKind (..))
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Auth.Token" $ do
  it "generates correctly prefixed unpadded write and service credentials" $ do
    Token write <- generateToken WriteKey
    Token service <- generateToken ServiceToken
    Text.length write `shouldBe` 49
    Text.length service `shouldBe` 49
    write `shouldSatisfy` Text.isPrefixOf "ksk_w_"
    service `shouldSatisfy` Text.isPrefixOf "ksk_s_"
    write `shouldNotBe` service

  it "hashes the full token to lowercase SHA-256 hex" $ do
    token@(Token plaintext) <- generateToken WriteKey
    let digest = hashToken token
    Text.length digest `shouldBe` 64
    Text.all (\character -> isDigit character || (isLower character && character >= 'a' && character <= 'f')) digest `shouldBe` True
    digest `shouldNotBe` plaintext

  it "classifies known prefixes and rejects other strings" $ do
    tokenKind "ksk_w_example" `shouldBe` Just WriteKey
    tokenKind "ksk_s_example" `shouldBe` Just ServiceToken
    tokenKind "garbage" `shouldBe` Nothing
