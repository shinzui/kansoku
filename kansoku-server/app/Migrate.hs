module Main (main) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text.IO qualified as Text
import Database.PostgreSQL.Migrate (defaultRunOptions)
import Database.PostgreSQL.Migrate.CLI
import Hasql.Connection.Settings qualified as Settings
import Kansoku.Config (Config (..), loadConfig)
import Kansoku.Migrations (kansokuMigrationPlan)
import Options.Applicative
import System.Exit qualified as Exit

main :: IO ()
main = do
  plan <- either (fail . show) pure kansokuMigrationPlan
  parsedCommand <-
    execParser
      ( info
          (migrationCommandParser plan <**> helper)
          (fullDesc <> progDesc "Manage the Kansoku PostgreSQL migration plan")
      )
  config <- loadConfig >>= either (fail . show) pure
  let environment =
        cliEnvironment
          (Settings.connectionString (pgConnectionString config))
          plan
          defaultRunOptions
  outcome <- runMigrationCommand environment parsedCommand
  case commandOutputFormat parsedCommand of
    TextOutput -> Text.putStrLn (renderMigrationCommandText outcome)
    JsonOutput -> LazyByteString.putStrLn (Aeson.encode (renderMigrationCommandJson outcome))
  Exit.exitWith $
    case exitClass outcome of
      ExitSucceeded -> Exit.ExitSuccess
      _ -> Exit.ExitFailure 1

commandOutputFormat :: MigrationCommand -> OutputFormat
commandOutputFormat parsedCommand =
  case parsedCommand of
    Plan PlanOptions {output = OutputOptions format} -> format
    List ListOptions {output = OutputOptions format} -> format
    Check CheckOptions {output = OutputOptions format} -> format
    Status StatusOptions {output = OutputOptions format} -> format
    Verify VerifyOptions {output = OutputOptions format} -> format
    Up UpOptions {output = OutputOptions format} -> format
    Repair RepairOptions {output = OutputOptions format} -> format
    New NewOptions {output = OutputOptions format} -> format
