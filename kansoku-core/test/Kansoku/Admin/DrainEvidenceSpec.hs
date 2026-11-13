module Kansoku.Admin.DrainEvidenceSpec (spec) where

import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime)
import Kansoku.Admin.DrainEvidence
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Admin.DrainEvidence" $ do
  it "accepts a current owner-bound operator attestation" $
    validate requirement document `shouldSatisfy` isRight
  it "rechecks expiration after waiting for exclusion" $ do
    case validate requirement document of
      Left failure -> expectationFailure (show failure)
      Right evidence -> do
        checkDrainCurrent (addUTCTime 59 now) evidence `shouldBe` Right ()
        checkDrainCurrent (addUTCTime 60 now) evidence `shouldSatisfy` isLeft
  it "identifies missing coverage without echoing untrusted input" $ do
    (() <$ validate (requirement {requiredSubmitters = ["missing-writer"]}) document) `shouldBe` Left "incomplete submitter coverage"
    (() <$ validate requirement (set "drainedAt" (A.String "secret-untrusted-value"))) `shouldBe` Left "invalid drain evidence fields"
  it "rejects a stale predecessor and a different owner kind" $ do
    validate (requirement {requiredOwner = MigrationSession "session" 4}) document `shouldSatisfy` isLeft
    validate (requirement {requiredOwner = DataJob "session" 3}) document `shouldSatisfy` isLeft
  it "requires all expected replicas, databases and submitters" $ do
    validate (requirement {requiredServers = ["server", "other"]}) document `shouldSatisfy` isLeft
    validate (requirement {requiredDatabases = ["analytics", "ledger", "extra"]}) document `shouldSatisfy` isLeft
    validate (requirement {requiredSubmitters = ["runtime", "scheduled-reader"]}) document `shouldSatisfy` isLeft
  it "refuses missing trusted coverage and wrong identities" $ do
    validate (requirement {requiredSubmitters = []}) document `shouldSatisfy` isLeft
    validate (requirement {requiredTarget = "other"}) document `shouldSatisfy` isLeft
    validate (requirement {requiredLedger = Just "other"}) document `shouldSatisfy` isLeft
  it "rejects expired, future and pre-fence exclusion" $ do
    validate requirement (set "expiresAt" (A.toJSON now)) `shouldSatisfy` isLeft
    validate requirement (set "drainedAt" (A.toJSON (addUTCTime 1 now))) `shouldSatisfy` isLeft
    validate requirement (set "drainedAt" (A.toJSON (addUTCTime (-1) now))) `shouldSatisfy` isLeft
  it "requires explicit attestation for schedules and background changes" $ do
    validate requirement (set "schedulesPaused" (A.Bool False)) `shouldSatisfy` isLeft
    validate requirement (set "backgroundChangesSettled" (A.Bool False)) `shouldSatisfy` isLeft
    validate requirement (set "operatorAttested" (A.Bool False)) `shouldSatisfy` isLeft
  it "rejects malformed, oversized, unknown and duplicate inventory input" $ do
    validateDrainEvidence now requirement (BS.replicate 65537 32) `shouldSatisfy` isLeft
    validateDrainEvidence now requirement "{" `shouldSatisfy` isLeft
    validate requirement (set "unknown" A.Null) `shouldSatisfy` isLeft
    validate requirement (set "servers" (A.toJSON (["server", "server"] :: [Text]))) `shouldSatisfy` isLeft
  where
    validate expected = validateDrainEvidence now expected . LBS.toStrict . A.encode
    set key value = case document of
      A.Object o -> A.Object (KM.insert key value o)
      _ -> error "invalid fixture"

now :: UTCTime
now = read "2026-11-13 18:00:00 UTC"

requirement :: DrainRequirement
requirement = DrainRequirement "target" ["server"] (Just "ledger-id") ["analytics", "ledger"] ["runtime"] ["migrator"] (MigrationSession "session" 3) now

document :: A.Value
document =
  A.object
    [ "schemaVersion" A..= (1 :: Int),
      "target" A..= ("target" :: Text),
      "servers" A..= (["server"] :: [Text]),
      "ledger" A..= ("ledger-id" :: Text),
      "databases" A..= (["analytics", "ledger"] :: [Text]),
      "submitters" A..= (["runtime"] :: [Text]),
      "availablePrincipals" A..= (["migrator"] :: [Text]),
      "owner" A..= A.object ["kind" A..= ("migration-session" :: Text), "id" A..= ("session" :: Text), "predecessor" A..= (3 :: Int)],
      "exclusionStartedAt" A..= now,
      "drainedAt" A..= now,
      "expiresAt" A..= addUTCTime 60 now,
      "procedureReference" A..= ("owned-fixture/receipt" :: Text),
      "procedureSha256" A..= (replicate 64 'a'),
      "submittersBlocked" A..= True,
      "schedulesPaused" A..= True,
      "backgroundChangesSettled" A..= True,
      "operatorAttested" A..= True
    ]
