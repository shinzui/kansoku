{-# LANGUAGE TemplateHaskell #-}

-- | Generated native expectations travel inside the executable, independently
-- of source files or the current working directory at inspection time.
module Kansoku.ClickHouseMigration.SchemaExpectation (document, digest, checkPlan) where

import ClickHouseMigrate.Plan (MigrationPlan)
import Control.Monad (unless)
import Data.Aeson qualified as A
import Data.ByteString.Char8 qualified as BS
import Data.Text (Text)
import Kansoku.Admin.Store (field)
import Kansoku.ClickHouseMigration.Recovery qualified as Recovery
import Language.Haskell.TH.Syntax (Exp (LitE), Lit (StringL), addDependentFile, makeRelativeToProject, runIO)

bytes :: BS.ByteString
bytes =
  BS.pack
    $( do
         path <- makeRelativeToProject "migrations/clickhouse/schema-expectation.json"
         addDependentFile path
         contents <- runIO (BS.readFile path)
         pure (LitE (StringL (BS.unpack contents)))
     )

document :: A.Value
document = either (const (error "Invalid embedded native schema expectation")) id (A.eitherDecodeStrict' bytes)

digest :: Text
digest = Recovery.recoveryBytesDigest bytes

checkPlan :: MigrationPlan -> Either Text ()
checkPlan plan = unless (field "schemaVersion" document == A.Number 1 && field "planSha256" document == A.String (Recovery.compiledPlanDigest plan)) (Left "Embedded restored-schema expectation does not match the compiled release plan")
