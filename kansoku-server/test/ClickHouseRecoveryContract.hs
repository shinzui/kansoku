module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Data.Text qualified
import Data.Time (UTCTime, addUTCTime)
import Kansoku.ClickHouseMigration.Recovery

main :: IO ()
main = do
  unless (isRight (validate document)) (fail "Complete recovery manifest refused")
  forM_ invalid $ \(label, value) -> unless (isLeft (validate value)) (fail ("Unsafe recovery manifest accepted: " <> label))
  unless (isLeft (validateRecoverySet now expected (BS.replicate 65537 32))) (fail "Oversized manifest accepted")
  case validate document of
    Left _ -> fail "Invalid positive fixture"
    Right accepted -> do
      unless (recoveryId accepted == "11111111-1111-4111-8111-111111111111") (fail "Recovery ID changed")
      unless (isLeft (checkRecoveryCurrent (addUTCTime 30 now) accepted)) (fail "Expired interval accepted")
  putStrLn (show (length invalid + 4) <> " recovery contract cases passed; 0 failures, 0 skipped")
  where
    validate = validateRecoverySet now expected . LBS.toStrict . A.encode
    invalid =
      [ ("schema", set "schemaVersion" (A.Number 2)),
        ("ID", set "id" (A.String "bad")),
        ("target", set "target" (A.String "other")),
        ("server inventory", set "servers" (A.toJSON (["other"] :: [Text]))),
        ("ledger", set "ledger" (A.String "other")),
        ("owner", set "session" (A.String "other")),
        ("boundary", set "predecessor" (A.Number 1)),
        ("plan", set "planSha256" (A.String "other")),
        ("drain", set "drainSha256" (A.String "other")),
        ("PostgreSQL database", set "postgresDatabase" (A.String "other")),
        ("coordinator snapshot", set "coordinatorState" A.Null),
        ("retention policy", set "retentionPolicy" A.Null),
        ("expired window", set "stableUntil" (A.toJSON now)),
        ("window before drain", set "stableFrom" (A.toJSON (addUTCTime (-61) now))),
        ("window beyond exclusion", set "stableUntil" (A.toJSON (addUTCTime 61 now))),
        ("coordinator phase", set "coordinatorSnapshotPhase" (A.String "unfenced")),
        ("background changes", set "backgroundChangesSettled" (A.Bool False)),
        ("attestation", set "operatorAttested" (A.Bool False)),
        ("missing ledger", set "snapshots" (A.toJSON (take 2 snapshots))),
        ("duplicate coverage", set "snapshots" (A.toJSON (replicate 3 firstSnapshot))),
        ("partial artifact", set "snapshots" (A.toJSON (change "complete" (A.Bool False) firstSnapshot : drop 1 snapshots))),
        ("late snapshot", set "snapshots" (A.toJSON (change "completedAt" (A.toJSON (addUTCTime 1 now)) firstSnapshot : drop 1 snapshots))),
        ("early snapshot", set "snapshots" (A.toJSON (change "startedAt" (A.toJSON (addUTCTime (-61) now)) firstSnapshot : drop 1 snapshots))),
        ("missing receipt", set "snapshots" (A.toJSON (change "verificationReference" (A.String "") firstSnapshot : drop 1 snapshots))),
        ("invalid digest", set "snapshots" (A.toJSON (change "artifactSha256" (A.String "bad") firstSnapshot : drop 1 snapshots))),
        ("unknown field", set "unknown" A.Null)
      ]
    set key value = change key value document
    firstSnapshot = case snapshots of
      x : _ -> x
      [] -> error "empty snapshot fixture"

change :: A.Key -> A.Value -> A.Value -> A.Value
change key value (A.Object object) = A.Object (KM.insert key value object)
change _ _ _ = error "invalid test fixture"

now :: UTCTime
now = read "2026-11-13 20:00:00 UTC"

expected :: RecoveryRequirement
expected = RecoveryRequirement "target" ["server"] "ledger" "session" 0 (replicateText 'a') (replicateText 'b') "postgres" policy bookkeeping (addUTCTime (-60) now) (addUTCTime 60 now)

policy :: A.Value
policy = A.object ["days" A..= (0 :: Int), "revision" A..= (0 :: Int), "cutoff" A..= A.Null]

replicateText :: Char -> Text
replicateText = Data.Text.replicate 64 . Data.Text.singleton

document :: A.Value
document =
  A.object
    [ "schemaVersion" A..= (1 :: Int),
      "id" A..= ("11111111-1111-4111-8111-111111111111" :: Text),
      "target" A..= ("target" :: Text),
      "servers" A..= (["server"] :: [Text]),
      "ledger" A..= ("ledger" :: Text),
      "session" A..= ("session" :: Text),
      "predecessor" A..= (0 :: Int),
      "planSha256" A..= replicateText 'a',
      "drainSha256" A..= replicateText 'b',
      "postgresDatabase" A..= ("postgres" :: Text),
      "retentionPolicy" A..= policy,
      "coordinatorState" A..= bookkeeping,
      "stableFrom" A..= addUTCTime (-60) now,
      "stableUntil" A..= addUTCTime 30 now,
      "coordinatorSnapshotPhase" A..= ("fenced-before-native-entry" :: Text),
      "backgroundChangesSettled" A..= True,
      "operatorAttested" A..= True,
      "snapshots" A..= snapshots
    ]

snapshots :: [A.Value]
snapshots = map snapshot [("postgresql", "postgres"), ("clickhouse", "analytics"), ("clickhouse", "kansoku_migration_ledger")]
  where
    snapshot (store, database) =
      A.object
        [ "store" A..= (store :: Text),
          "database" A..= (database :: Text),
          "startedAt" A..= addUTCTime (-20) now,
          "completedAt" A..= addUTCTime (-5) now,
          "artifactReference" A..= ("owned/backup" :: Text),
          "artifactSha256" A..= replicateText 'c',
          "verificationReference" A..= ("owned/verification" :: Text),
          "verificationSha256" A..= replicateText 'd',
          "complete" A..= True
        ]

bookkeeping :: A.Value
bookkeeping = A.object ["entry" A..= (0 :: Int), "outcome" A..= ("pre-session" :: Text), "pendingEntry" A..= ("pre-session-drain" :: Text), "pendingReceipts" A..= ([] :: [Text])]
