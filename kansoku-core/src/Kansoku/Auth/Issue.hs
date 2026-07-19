-- | One-time credential issuance.
module Kansoku.Auth.Issue
  ( issueKey,
  )
where

import Hasql.Pool qualified as Pool
import Kansoku.Auth.Store (AuthStoreError, insertApiKey)
import Kansoku.Auth.Token (Token, generateToken, hashToken)
import Kansoku.Auth.Types (ApiKeyId, CredentialKind)
import Kansoku.Event (AccountId)
import Kansoku.Prelude

issueKey :: Pool.Pool -> CredentialKind -> AccountId -> Text -> IO (Either AuthStoreError (ApiKeyId, Token))
issueKey pool kind accountId description = do
  token <- generateToken kind
  inserted <- insertApiKey pool kind (hashToken token) accountId description
  pure ((,token) <$> inserted)
