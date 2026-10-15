module Kansoku.PostgresTestSupport (withMigratedPool, withMigratedStore, withCommitFault) where

import Control.Exception (bracket, finally)
import Data.Text (Text)
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate.Test (withMigratedDatabase)
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kansoku.Migrations (kansokuMigrationPlan)
import Kansoku.Postgres (createPool)
import System.Directory (doesFileExist)
import System.IO (Handle, hGetLine)
import System.Process
import System.Timeout (timeout)
import Test.Hspec

withMigratedPool :: (Pool.Pool -> Expectation) -> Expectation
withMigratedPool action = withMigratedStore (\_ _ -> action)

withMigratedStore :: (Text -> Connection.Connection -> Pool.Pool -> Expectation) -> Expectation
withMigratedStore action = do
  plan <- either (fail . show) pure kansokuMigrationPlan
  result <- withMigratedDatabase plan $ \connection -> do
    settings <- Connection.use connection (Session.statement () connectionInfo) >>= either (fail . show) pure
    bracket (createPool settings) Pool.release (action settings connection)
  either (expectationFailure . show) pure result
  where
    connectionInfo =
      Statement.preparable
        "SELECT 'host=' || current_setting('unix_socket_directories') || ' port=' || current_setting('port') || ' user=' || current_user || ' dbname=' || current_database()"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.text)))

withCommitFault :: Text -> (Text -> Handle -> IO a) -> IO a
withCommitFault settings action = do
  script <- doesFileExist "scripts/pg_commit_fault.py" >>= \exists -> pure (if exists then "scripts/pg_commit_fault.py" else "../scripts/pg_commit_fault.py")
  let fields = Text.words settings
      field key = maybe (error "missing private PostgreSQL setting") (Text.drop (Text.length key + 1)) (findField key fields)
      socket = Text.unpack (field "host" <> "/.s.PGSQL." <> field "port")
      process = (proc "python3" [script, socket]) {std_out = CreatePipe}
  withCreateProcess process $ \_ output _ handle -> (`finally` terminateProcess handle) $ do
    pipe <- maybe (fail "missing proxy output") pure output
    port <- (timeout 8_000_000 (hGetLine pipe) >>= maybe (fail "PostgreSQL fault proxy startup timed out") pure)
    let target = Text.unwords (filter (\s -> not ("host=" `Text.isPrefixOf` s || "port=" `Text.isPrefixOf` s)) fields) <> " host=127.0.0.1 port=" <> Text.pack port <> " sslmode=disable gssencmode=disable"
    action target pipe
  where
    findField _ [] = Nothing
    findField key (x : xs)
      | (key <> "=") `Text.isPrefixOf` x = Just x
      | otherwise = findField key xs
