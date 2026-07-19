-- | PostgreSQL-backed credential storage. Plaintext tokens never cross this boundary.
module Kansoku.Auth.Store
  ( AuthStoreError (..),
    insertApiKey,
    lookupApiKey,
  )
where

import Data.Bifunctor (first)
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.UUID (UUID)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Kansoku.Auth.Types
  ( ApiKeyId (..),
    AuthenticatedPrincipal (..),
    CredentialKind,
    credentialKindText,
    parseCredentialKind,
  )
import Kansoku.Event (AccountId (..))
import Kansoku.Prelude

data AuthStoreError
  = AuthStoreUsageError !Pool.UsageError
  | InvalidStoredCredentialKind !Text
  deriving stock (Show)

data NewApiKey = NewApiKey
  { kind :: !CredentialKind,
    tokenHash :: !Text,
    accountId :: !AccountId,
    description :: !Text
  }
  deriving stock (Generic)

insertApiKey :: Pool.Pool -> CredentialKind -> Text -> AccountId -> Text -> IO (Either AuthStoreError ApiKeyId)
insertApiKey pool kind tokenHash accountId description =
  first AuthStoreUsageError . fmap ApiKeyId
    <$> Pool.use pool (Session.statement NewApiKey {kind, tokenHash, accountId, description} insertApiKeyStatement)

lookupApiKey :: Pool.Pool -> Text -> IO (Either AuthStoreError (Maybe AuthenticatedPrincipal))
lookupApiKey pool tokenHash = do
  result <- Pool.use pool (Session.statement tokenHash lookupApiKeyStatement)
  pure $ do
    stored <- first AuthStoreUsageError result
    traverse principalFromStored stored

insertApiKeyStatement :: Statement NewApiKey UUID
insertApiKeyStatement =
  Statement.preparable
    """
    INSERT INTO kansoku.api_keys (kind, token_hash, account_id, description)
    VALUES ($1, $2, $3, $4)
    RETURNING id
    """
    ( ((credentialKindText . view #kind) >$< textParam)
        <> (view #tokenHash >$< textParam)
        <> ((unAccountId . view #accountId) >$< textParam)
        <> (view #description >$< textParam)
    )
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.uuid)))

lookupApiKeyStatement :: Statement Text (Maybe (UUID, Text, Text))
lookupApiKeyStatement =
  Statement.preparable
    """
    SELECT id, kind, account_id
    FROM kansoku.api_keys
    WHERE token_hash = $1 AND revoked_at IS NULL
    """
    textParam
    ( Decoders.rowMaybe
        ( (,,)
            <$> Decoders.column (Decoders.nonNullable Decoders.uuid)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
        )
    )

textParam :: Encoders.Params Text
textParam = Encoders.param (Encoders.nonNullable Encoders.text)

principalFromStored :: (UUID, Text, Text) -> Either AuthStoreError AuthenticatedPrincipal
principalFromStored (keyId, rawKind, accountId) = do
  kind <- maybe (Left (InvalidStoredCredentialKind rawKind)) Right (parseCredentialKind rawKind)
  pure
    AuthenticatedPrincipal
      { keyId = ApiKeyId keyId,
        kind,
        accountId = AccountId accountId
      }
