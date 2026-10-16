-- | Shared credential issuance for the administrative executable and server alias.
module Kansoku.Admin.Keys (runIssueKey) where

import Control.Exception (bracket)
import Data.Text qualified as Text
import Hasql.Pool qualified as Pool
import Kansoku.Auth.Issue (issueKey)
import Kansoku.Auth.Token (Token (..))
import Kansoku.Auth.Types (CredentialKind (..), apiKeyIdText, credentialKindText)
import Kansoku.Config (loadConfig)
import Kansoku.Event (AccountId (..))
import Kansoku.Postgres (createPool)
import Kansoku.Prelude
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

data IssueOptions = IssueOptions
  { kind :: !CredentialKind,
    accountId :: !AccountId,
    description :: !Text
  }
  deriving stock (Generic)

runIssueKey :: [String] -> IO ()
runIssueKey args =
  case parseIssueOptions args of
    Left message -> hPutStrLn stderr message >> usageFailure
    Right options -> do
      result <- loadConfig
      case result of
        Left err -> hPutStrLn stderr ("configuration error: " <> show err) >> exitFailure
        Right cfg ->
          bracket (createPool (cfg ^. #pgConnectionString)) Pool.release $ \pool -> do
            issued <- issueKey pool (options ^. #kind) (options ^. #accountId) (options ^. #description)
            case issued of
              Left err -> hPutStrLn stderr ("key issuance failed: " <> show err) >> exitFailure
              Right (keyId, Token token) -> do
                putStrLn
                  ( "issued "
                      <> Text.unpack (credentialKindText (options ^. #kind))
                      <> " "
                      <> Text.unpack (apiKeyIdText keyId)
                      <> " for account "
                      <> Text.unpack (unAccountId (options ^. #accountId))
                  )
                putStrLn (Text.unpack token)
                putStrLn "store this token now; it cannot be shown again"

parseIssueOptions :: [String] -> Either String IssueOptions
parseIssueOptions = go Nothing Nothing ""
  where
    go maybeKind maybeAccount description = \case
      [] -> do
        kind <- maybe (Left "missing --kind") Right maybeKind
        account <- maybe (Left "missing --account") Right maybeAccount
        unless (not (Text.null account)) (Left "--account must not be empty")
        pure IssueOptions {kind, accountId = AccountId account, description}
      "--kind" : value : rest -> do
        kind <-
          case value of
            "write" -> Right WriteKey
            "service" -> Right ServiceToken
            _ -> Left "--kind must be write or service"
        go (Just kind) maybeAccount description rest
      "--account" : value : rest ->
        go maybeKind (Just (Text.pack value)) description rest
      "--description" : value : rest ->
        go maybeKind maybeAccount (Text.pack value) rest
      flag : _ -> Left ("unrecognized or incomplete issue-key argument: " <> flag)

usageFailure :: IO a
usageFailure = do
  hPutStrLn stderr "usage: kansoku-admin issue-key --kind write|service --account ACCOUNT [--description TEXT]"
  exitFailure
