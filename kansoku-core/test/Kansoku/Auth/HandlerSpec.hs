{-# LANGUAGE TypeApplications #-}

module Kansoku.Auth.HandlerSpec (spec) where

import Control.Monad (void)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.UUID qualified as UUID
import Hasql.Pool qualified as Pool
import Kansoku.Api.Response (ProblemDetails (..))
import Kansoku.Auth.Handler
import Kansoku.Auth.Store (AuthStoreError (..))
import Kansoku.Auth.Token (Token (..), hashToken)
import Kansoku.Auth.Types
import Kansoku.Event (AccountId (..))
import Kansoku.Ingest.RequestContext (emptyRequestContext)
import Network.HTTP.Types.Header (RequestHeaders, hAuthorization, hWWWAuthenticate)
import Network.Wai (Request (pathInfo, queryString, rawPathInfo, requestHeaders), defaultRequest)
import Servant (ServerError (..), runHandler)
import Servant.Server.Experimental.Auth (AuthHandler, unAuthHandler)
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Auth.Handler" $ do
  it "returns an envelope 401 plus Bearer challenge when credentials are absent" $ do
    result <- runAuth (ingestAuthHandlerWith fixtureLookup) []
    err <- expectServerError 401 result
    lookup hWWWAuthenticate (errHeaders err) `shouldBe` Just "Bearer"
    envelope <- decodeEnvelope err
    code envelope `shouldBe` "unauthorized"
    retryable envelope `shouldBe` False

  it "returns the same 401 for an unknown credential" $ do
    result <- runAuth (ingestAuthHandlerWith fixtureLookup) [(hAuthorization, "Bearer ksk_w_unknown")]
    err <- expectServerError 401 result
    detail <$> decodeEnvelope err `shouldReturn` "missing or unknown credential"

  it "accepts write keys through X-Api-Key and case-insensitive Bearer transport" $ do
    xApiKey <- runAuth (ingestAuthHandlerWith fixtureLookup) [("X-Api-Key", writeToken)]
    bearer <- runAuth (ingestAuthHandlerWith fixtureLookup) [(hAuthorization, "bEaReR " <> writeToken)]
    xApiKey `shouldBe` Right (IngestPrincipal writePrincipal emptyRequestContext)
    bearer `shouldBe` Right (IngestPrincipal writePrincipal emptyRequestContext)

  it "uses Authorization precedence when both credential headers are present" $ do
    result <-
      runAuth
        (ingestAuthHandlerWith fixtureLookup)
        [(hAuthorization, "Bearer " <> writeToken), ("X-Api-Key", "ksk_w_unknown")]
    result `shouldBe` Right (IngestPrincipal writePrincipal emptyRequestContext)

  it "does not fall through to X-Api-Key when Authorization is malformed" $ do
    result <-
      runAuth
        (ingestAuthHandlerWith fixtureLookup)
        [(hAuthorization, "Basic ignored"), ("X-Api-Key", writeToken)]
    void (expectServerError 401 result)

  it "rejects a real write key on metrics with 403 and accepts a service token" $ do
    forbidden <- runAuth (metricsAuthHandlerWith fixtureLookup) [("X-Api-Key", writeToken)]
    err <- expectServerError 403 forbidden
    code <$> decodeEnvelope err `shouldReturn` "forbidden"

    accepted <- runAuth (metricsAuthHandlerWith fixtureLookup) [(hAuthorization, "Bearer " <> serviceToken)]
    accepted `shouldBe` Right (MetricsPrincipal servicePrincipal)

  it "validates metric parameters after authentication and returns invalid_filter before routing" $ do
    let handler = metricsAuthHandlerWith fixtureLookup
        request headers query = defaultRequest {requestHeaders = headers, pathInfo = [], rawPathInfo = "/metrics/events", queryString = query}
        run headers query = runHandler (unAuthHandler handler (request headers query))
        malformed = [("filter", Just "not-json")]
    absent <- run [] malformed
    void (expectServerError 401 absent)
    write <- run [("X-Api-Key", writeToken)] malformed
    void (expectServerError 403 write)
    malformedResult <- run [("X-Api-Key", serviceToken)] malformed
    malformedError <- expectServerError 400 malformedResult
    code <$> decodeEnvelope malformedError `shouldReturn` "invalid_filter"
    unknown <- run [("X-Api-Key", serviceToken)] [("typo", Just "value")]
    unknownError <- expectServerError 400 unknown
    code <$> decodeEnvelope unknownError `shouldReturn` "unsupported_query_parameter"

  it "maps credential-store failure to retryable 503" $ do
    let failingLookup _ = pure (Left (AuthStoreUsageError Pool.AcquisitionTimeoutUsageError))
    result <- runAuth (ingestAuthHandlerWith failingLookup) [("X-Api-Key", writeToken)]
    err <- expectServerError 503 result
    envelope <- decodeEnvelope err
    code envelope `shouldBe` "auth_store_unavailable"
    retryable envelope `shouldBe` True

runAuth :: AuthHandler Request principal -> RequestHeaders -> IO (Either ServerError principal)
runAuth handler headers =
  runHandler (unAuthHandler handler defaultRequest {requestHeaders = headers})

expectServerError :: Int -> Either ServerError principal -> IO ServerError
expectServerError expected = \case
  Left err -> err <$ (errHTTPCode err `shouldBe` expected)
  Right _ -> expectationFailure ("expected HTTP " <> show expected) >> fail "authentication unexpectedly succeeded"

decodeEnvelope :: ServerError -> IO ProblemDetails
decodeEnvelope err =
  case Aeson.eitherDecode (errBody err) of
    Right envelope -> pure envelope
    Left message -> expectationFailure ("invalid auth error envelope: " <> message) >> fail message

writeToken :: ByteString
writeToken = "ksk_w_fixture"

serviceToken :: ByteString
serviceToken = "ksk_s_fixture"

fixtureLookup :: PrincipalLookup
fixtureLookup digest = pure (Right (Map.lookup digest fixtures))

fixtures :: Map.Map Text AuthenticatedPrincipal
fixtures =
  Map.fromList
    [ (hashToken (Token "ksk_w_fixture"), writePrincipal),
      (hashToken (Token "ksk_s_fixture"), servicePrincipal)
    ]

writePrincipal :: AuthenticatedPrincipal
writePrincipal = fixturePrincipal WriteKey "acct_write"

servicePrincipal :: AuthenticatedPrincipal
servicePrincipal = fixturePrincipal ServiceToken "acct_service"

fixturePrincipal :: CredentialKind -> Text -> AuthenticatedPrincipal
fixturePrincipal kind accountId =
  AuthenticatedPrincipal
    { keyId = ApiKeyId UUID.nil,
      kind,
      accountId = AccountId accountId
    }
