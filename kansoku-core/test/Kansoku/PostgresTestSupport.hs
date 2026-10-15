module Kansoku.PostgresTestSupport (withMigratedPool, withMigratedStore) where

import Control.Exception (bracket)
import Data.Text (Text)
import Database.PostgreSQL.Migrate.Test (withMigratedDatabase)
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kansoku.Migrations (kansokuMigrationPlan)
import Kansoku.Postgres (createPool)
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
