module Kansoku.MigrationsSpec (spec) where

import Data.Either (isRight)
import Data.Foldable (toList)
import Database.PostgreSQL.Migrate
  ( MigrationOutcome (..),
    MigrationReport (..),
    MigrationResult (..),
    VerificationReport (..),
    connectionProvider,
    defaultRunOptions,
    runMigrationPlanWith,
    verifyMigrationPlanWith,
  )
import Database.PostgreSQL.Migrate.Test (withMigratedDatabase)
import Hasql.Connection qualified as Connection
import Kansoku.Ingest.Queue (eventsQueueName)
import Kansoku.Migrations (kansokuMigrationPlan)
import Pgmq qualified
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Migrations" $ do
  it "constructs the PGMQ-only application plan" $
    kansokuMigrationPlan `shouldSatisfy` isRight

  it "applies, strictly verifies, reapplies without work, and provisions the queue" $ do
    plan <-
      case kansokuMigrationPlan of
        Left err -> expectationFailure (show err) >> fail "invalid Kansoku migration plan"
        Right validPlan -> pure validPlan
    migrated <-
      withMigratedDatabase plan $ \connection -> do
        let provider = connectionProvider (\action -> Right <$> action connection)

        verified <- verifyMigrationPlanWith defaultRunOptions provider plan
        case verified of
          Left err -> expectationFailure ("strict migration verification failed: " <> show err)
          Right VerificationReport {issues, pendingMigrations, unknownMigrations} -> do
            issues `shouldBe` []
            pendingMigrations `shouldBe` []
            unknownMigrations `shouldBe` []

        secondRun <- runMigrationPlanWith defaultRunOptions provider plan
        case secondRun of
          Left err -> expectationFailure ("second migration application failed: " <> show err)
          Right MigrationReport {results} ->
            fmap outcome (toList results) `shouldSatisfy` all (== AlreadyApplied)

        created <- Connection.use connection (Pgmq.createQueue (eventsQueueName "kansoku_migration_spec"))
        case created of
          Left err -> expectationFailure ("queue provisioning failed after migration: " <> show err)
          Right () -> pure ()

    case migrated of
      Left err -> expectationFailure ("ephemeral migrated database failed: " <> show err)
      Right () -> pure ()
