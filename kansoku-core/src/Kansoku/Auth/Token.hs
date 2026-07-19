-- | Generation, classification, and one-way hashing for Kansoku credentials.
module Kansoku.Auth.Token
  ( Token (..),
    generateToken,
    hashToken,
    tokenKind,
  )
where

import Crypto.Hash (Digest, SHA256 (..), hashWith)
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString.Base64.URL qualified as Base64Url
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kansoku.Auth.Types (CredentialKind (..))
import Kansoku.Prelude

newtype Token = Token {unToken :: Text}
  deriving stock (Generic, Show)
  deriving newtype (Eq)

generateToken :: CredentialKind -> IO Token
generateToken kind = do
  entropy <- getRandomBytes 32 :: IO ByteString
  pure . Token $ tokenPrefix kind <> Text.decodeUtf8 (Base64Url.encodeUnpadded entropy)

hashToken :: Token -> Text
hashToken (Token token) =
  Text.pack (show (hashWith SHA256 (Text.encodeUtf8 token) :: Digest SHA256))

tokenKind :: Text -> Maybe CredentialKind
tokenKind token
  | "ksk_w_" `Text.isPrefixOf` token = Just WriteKey
  | "ksk_s_" `Text.isPrefixOf` token = Just ServiceToken
  | otherwise = Nothing

tokenPrefix :: CredentialKind -> Text
tokenPrefix = \case
  WriteKey -> "ksk_w_"
  ServiceToken -> "ksk_s_"
