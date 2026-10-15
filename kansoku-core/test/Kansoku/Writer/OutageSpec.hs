module Kansoku.Writer.OutageSpec (spec) where

import Data.Text qualified as Text
import Kansoku.PostgresTestSupport (withMigratedStore)
import System.Directory (doesFileExist)
import System.Environment (getEnv, getEnvironment)
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec

-- This dedicated entry point owns PostgreSQL; its Python child owns the native
-- ClickHouse/proxy/server processes. The ordinary deterministic suite excludes
-- this duration-based capacity proof. The launcher audits a nonzero Hspec run.
spec :: Spec
spec = describe "Kansoku.Writer.Outage native" $
  it "retains accepted events through a real storage outage and writer restart" $
    withMigratedStore $ \settings _ _ -> do
      server <- getEnv "KANSOKU_OUTAGE_SERVER"
      duration <- getEnv "KANSOKU_OUTAGE_SECONDS"
      environment <- getEnvironment
      exists <- doesFileExist "scripts/pipeline-outage.py"
      let script = if exists then "scripts/pipeline-outage.py" else "../scripts/pipeline-outage.py"
          child =
            (proc "python3" [script, "--server", server, "--seconds", duration])
              { env = Just (("KANSOKU_OUTAGE_PG", Text.unpack settings) : environment)
              }
      (status, output, errors) <- readCreateProcessWithExitCode child ""
      putStr output
      case status of
        ExitSuccess -> pure ()
        ExitFailure _ -> expectationFailure ("owned pipeline outage proof failed: " <> errors)
