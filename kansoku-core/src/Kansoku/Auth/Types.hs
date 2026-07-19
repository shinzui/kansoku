-- | Domain types shared by credential issuance and request authentication.
module Kansoku.Auth.Types
  ( ApiKeyId (..),
    AuthenticatedPrincipal (..),
    CredentialKind (..),
    IngestPrincipal (..),
    MetricsPrincipal (..),
    apiKeyIdText,
    credentialKindText,
    parseCredentialKind,
  )
where

import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Kansoku.Event (AccountId)
import Kansoku.Prelude

data CredentialKind = WriteKey | ServiceToken
  deriving stock (Generic, Eq, Show)

credentialKindText :: CredentialKind -> Text
credentialKindText = \case
  WriteKey -> "write_key"
  ServiceToken -> "service_token"

parseCredentialKind :: Text -> Maybe CredentialKind
parseCredentialKind = \case
  "write_key" -> Just WriteKey
  "service_token" -> Just ServiceToken
  _ -> Nothing

newtype ApiKeyId = ApiKeyId {unApiKeyId :: UUID}
  deriving stock (Generic, Show)
  deriving newtype (Eq)

apiKeyIdText :: ApiKeyId -> Text
apiKeyIdText = UUID.toText . unApiKeyId

data AuthenticatedPrincipal = AuthenticatedPrincipal
  { keyId :: !ApiKeyId,
    kind :: !CredentialKind,
    accountId :: !AccountId
  }
  deriving stock (Generic, Eq, Show)

newtype IngestPrincipal = IngestPrincipal {principal :: AuthenticatedPrincipal}
  deriving stock (Generic, Eq, Show)

newtype MetricsPrincipal = MetricsPrincipal {principal :: AuthenticatedPrincipal}
  deriving stock (Generic, Eq, Show)
