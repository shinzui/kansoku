{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Servant authentication handlers for ingest and metrics route families.
module Kansoku.Auth.Handler
  ( PrincipalLookup,
    authContext,
    authContextWith,
    authenticateWith,
    ingestAuthHandler,
    ingestAuthHandlerWith,
    metricsAuthHandler,
    metricsAuthHandlerWith,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.Char qualified as Char
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Hasql.Pool qualified as Pool
import Kansoku.Api.Response (ProblemDetails, forbidden, unauthorized, unavailable)
import Kansoku.Auth.Store (AuthStoreError, lookupApiKey)
import Kansoku.Auth.Token (Token (..), hashToken, tokenKind)
import Kansoku.Auth.Types
  ( AuthenticatedPrincipal,
    CredentialKind (..),
    IngestPrincipal (..),
    MetricsPrincipal (..),
  )
import Kansoku.Prelude hiding (Context)
import Network.HTTP.Types.Header (RequestHeaders, hAuthorization, hContentType, hWWWAuthenticate)
import Network.Wai (Request, requestHeaders)
import Servant
  ( Context (..),
    Handler,
    ServerError (..),
    err401,
    err403,
    err503,
    throwError,
  )
import Servant.API.Experimental.Auth (AuthProtect)
import Servant.Server.Experimental.Auth
  ( AuthHandler,
    AuthServerData,
    mkAuthHandler,
  )

type instance AuthServerData (AuthProtect "kansoku-ingest") = IngestPrincipal

type instance AuthServerData (AuthProtect "kansoku-metrics") = MetricsPrincipal

type PrincipalLookup = Text -> IO (Either AuthStoreError (Maybe AuthenticatedPrincipal))

authenticateWith :: PrincipalLookup -> Request -> Handler AuthenticatedPrincipal
authenticateWith lookupPrincipal request = do
  rawToken <- either (const rejectUnauthorized) pure (presentedToken request)
  when (isNothing (tokenKind rawToken)) rejectUnauthorized
  result <- liftIO (lookupPrincipal (hashToken (Token rawToken)))
  case result of
    Left _storeError ->
      throwEnvelope
        err503
        (unavailable "auth_store_unavailable" "credential store is unavailable")
    Right Nothing -> rejectUnauthorized
    Right (Just principal) -> pure principal

ingestAuthHandler :: Pool.Pool -> AuthHandler Request IngestPrincipal
ingestAuthHandler pool = ingestAuthHandlerWith (lookupApiKey pool)

ingestAuthHandlerWith :: PrincipalLookup -> AuthHandler Request IngestPrincipal
ingestAuthHandlerWith lookupPrincipal =
  mkAuthHandler (fmap IngestPrincipal . authenticateWith lookupPrincipal)

metricsAuthHandler :: Pool.Pool -> AuthHandler Request MetricsPrincipal
metricsAuthHandler pool = metricsAuthHandlerWith (lookupApiKey pool)

metricsAuthHandlerWith :: PrincipalLookup -> AuthHandler Request MetricsPrincipal
metricsAuthHandlerWith lookupPrincipal =
  mkAuthHandler $ \request -> do
    principal <- authenticateWith lookupPrincipal request
    case principal ^. #kind of
      WriteKey ->
        throwEnvelope
          err403
          (forbidden "forbidden" "write keys cannot read metrics")
      ServiceToken -> pure (MetricsPrincipal principal)

authContext :: Pool.Pool -> Context '[AuthHandler Request IngestPrincipal, AuthHandler Request MetricsPrincipal]
authContext pool = authContextWith (lookupApiKey pool)

authContextWith :: PrincipalLookup -> Context '[AuthHandler Request IngestPrincipal, AuthHandler Request MetricsPrincipal]
authContextWith lookupPrincipal =
  ingestAuthHandlerWith lookupPrincipal
    :. metricsAuthHandlerWith lookupPrincipal
    :. EmptyContext

presentedToken :: Request -> Either () Text
presentedToken request =
  case lookup hAuthorization headers of
    Just authorization -> parseBearer authorization
    Nothing ->
      maybe (Left ()) decodeToken (lookup "X-Api-Key" headers)
  where
    headers = requestHeaders request

parseBearer :: ByteString.ByteString -> Either () Text
parseBearer value =
  case ByteString.break (== 32) value of
    (scheme, rest)
      | ByteString.Char8.map Char.toLower scheme == "bearer",
        Just token <- ByteString.stripPrefix " " rest,
        not (ByteString.null token),
        ByteString.all (> 32) token ->
          decodeToken token
    _ -> Left ()

decodeToken :: ByteString.ByteString -> Either () Text
decodeToken bytes =
  case Text.Encoding.decodeUtf8' bytes of
    Right token | not (Text.null token) -> Right token
    _ -> Left ()

rejectUnauthorized :: Handler a
rejectUnauthorized =
  throwEnvelopeWith
    err401
    [(hWWWAuthenticate, "Bearer")]
    (unauthorized "unauthorized" "missing or unknown credential")

throwEnvelope :: ServerError -> ProblemDetails -> Handler a
throwEnvelope err = throwEnvelopeWith err []

throwEnvelopeWith :: ServerError -> RequestHeaders -> ProblemDetails -> Handler a
throwEnvelopeWith err extraHeaders envelope =
  throwError
    err
      { errBody = Aeson.encode envelope,
        errHeaders = (hContentType, "application/problem+json") : extraHeaders
      }
