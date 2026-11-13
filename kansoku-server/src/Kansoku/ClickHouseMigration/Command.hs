module Kansoku.ClickHouseMigration.Command (mainWith) where

import ClickHouseMigrate.CLI
import ClickHouseMigrate.Error (PlanError)
import ClickHouseMigrate.Event (quietEvents, redactedDiagnostics)
import ClickHouseMigrate.Event qualified as Event
import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Plan (MigrationPlan)
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target qualified as T
import Control.Applicative (many, optional, some, (<**>), (<|>))
import Control.Exception (IOException, fromException)
import Control.Monad (forM, unless)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.List.NonEmpty qualified as NE
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.IO qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Kansoku.Admin.Coordination qualified as C
import Kansoku.Admin.DrainEvidence qualified as Drain
import Kansoku.ClickHouseMigration.Config qualified as Config
import Kansoku.ClickHouseMigration.Coordinator (sessionEvents, verifySessions, withCoordinator)
import Kansoku.ClickHouseMigration.Rebind qualified as Rebind
import Kansoku.ClickHouseMigration.RecoveryGate qualified as Backup
import Kansoku.ClickHouseMigration.Restored qualified as Restored
import Kansoku.Exception (trySynchronous)
import Options.Applicative qualified as O
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (stderr)
import System.IO.Error (ioeGetErrorString, isUserError)

data ApplicationCommand = Native !Invocation | Begin !OutputFormat !T.TargetKey !AuditInput | Finish !OutputFormat !T.TargetKey !AuditInput | SessionStatus !OutputFormat | RecoveryContext !OutputFormat | RecoveryObservation !OutputFormat | RebindServer !OutputFormat !T.TargetKey !Text !Text !FilePath !FilePath !AuditInput | RestoredCopy !OutputFormat !Restored.Options | RestoredExpectations !OutputFormat | Reconcile !OutputFormat !T.TargetKey !AuditInput ![L.AppendReceipt]

-- The toolkit parser remains authoritative for its command syntax. The outer
-- option binds quiescence to a specific persisted application session entry.
parser :: O.Parser (Maybe Integer, Maybe FilePath, Maybe FilePath, ApplicationCommand)
parser = (,,,) <$> optional (O.option O.auto (O.long "predecessor" <> O.metavar "ENTRY" <> O.help "Quiescence evidence applies to this exact session entry counter")) <*> optional (O.strOption (O.long "drain-evidence" <> O.metavar "FILE" <> O.help "Bounded portable operator drain attestation")) <*> optional (O.strOption (O.long "recovery-set" <> O.metavar "FILE" <> O.help "Complete pre-change recovery-set manifest")) <*> (Native <$> commandParser <|> maintenance <|> restored)
  where
    restored =
      O.hsubparser (O.command "verify-restored" (O.info (RestoredCopy <$> format <*> (Restored.Options <$> value "endpoint" <*> value "server" <*> value "original-target" <*> value "original-ledger" <*> value "application-database" <*> value "ledger-database" <*> value "expect-plan-sha256" <*> value "expected-definer" <*> optional (O.strOption (O.long "expected-policy" <> O.metavar "FILE"))) <**> O.helper) (O.progDesc "Inspect explicit scratch namespaces read-only; never authorize live mutation")))
        <|> O.hsubparser (O.command "restored-expectations" (O.info (RestoredExpectations <$> format <**> O.helper) (O.progDesc "Show offline release-bound restored-schema expectations")))
    maintenance = O.hsubparser (O.command "maintenance" (O.info commands (O.progDesc "Persist or finish a fenced administrative session")))
    receipts = many (O.option (O.eitherReader (either (const (Left "Invalid append receipt")) Right . L.parseAppendReceipt . Text.pack)) (O.long "pending-append" <> O.metavar "RECEIPT"))
    quietAudit = O.flag' () (O.long "quiescent" <> O.help "Submitting clients stopped and every predecessor request drained") *> audit True
    commands =
      O.hsubparser
        ( O.command "reconcile" (O.info (Reconcile <$> format <*> expected <*> quietAudit <*> receipts <**> O.helper) (O.progDesc "Reconcile retained receipts read-only under exclusion; acknowledge only compatible, resolved history"))
            <> O.command "recovery-context" (O.info (RecoveryContext <$> format <**> O.helper) (O.progDesc "Read the fenced owner, compiled plan digest and backup snapshot expectations"))
            <> O.command "recovery-observation" (O.info (RecoveryObservation <$> format <**> O.helper) (O.progDesc "Read qualified candidate native history; does not adopt the target"))
            <> O.command "rebind" (O.info (RebindServer <$> format <*> expected <*> value "old-server" <*> value "new-server" <*> O.strOption (O.long "original-drain" <> O.metavar "FILE") <*> O.strOption (O.long "restore-verification" <> O.metavar "FILE") <*> audit True <**> O.helper) (O.progDesc "Explicitly adopt a verified rebuilt direct server; preserve the fence and receipts"))
            <> O.command "status" (O.info (SessionStatus <$> format <**> O.helper) (O.progDesc "Read the retained session and predecessor counter without acquiring administrator exclusion"))
            <> O.command "begin" (O.info (Begin <$> format <*> expected <*> audit False <**> O.helper) (O.progDesc "Fence traffic; retain a session and ledger identity before any native submission"))
            <> O.command "finish" (O.info (Finish <$> format <*> expected <*> (O.flag' () (O.long "quiescent" <> O.help "All predecessor requests drained and submitting clients stopped") *> audit True) <**> O.helper) (O.progDesc "Verify current native history under exclusion, then close the persistent fence"))
        )
        <**> O.helper
    format = O.flag TextOutput JsonOutput (O.long "json")
    expected = O.option (O.eitherReader (either (const (Left "Invalid target")) Right . T.targetKey . Text.pack)) (O.long "expect-target" <> O.metavar "TARGET")
    value name = Text.pack <$> O.strOption (O.long name <> O.metavar (map upper name))
    upper c = if c >= 'a' && c <= 'z' then toEnum (fromEnum c - 32) else c
    audit required = AuditInput <$> value "actor" <*> value "reason" <*> (if required then some (value "evidence") else many (value "evidence"))

mainWith :: (T.TargetTopology -> [String] -> ([String], Either PlanError MigrationPlan)) -> IO ()
mainWith choose = do
  result <- trySynchronous (run choose)
  case result of
    Right () -> pure ()
    Left exception -> case fromException exception of
      Just code -> exitWith code
      Nothing -> do
        case fromException exception :: Maybe IOException of
          Just refusal | isUserError refusal -> Text.hPutStrLn stderr (Text.pack (ioeGetErrorString refusal))
          _ -> Text.hPutStrLn stderr "ClickHouse administration failed; any persisted fence remains active. Check target configuration, session ownership and predecessor evidence; use status/history for native diagnostics."
        exitFailure

run :: (T.TargetTopology -> [String] -> ([String], Either PlanError MigrationPlan)) -> IO ()
run choose = do
  rawArgs <- getArgs
  inspectionTopology <- T.DirectServer <$> either (const (fail "Invalid internal inspection topology")) pure (T.serverId "00000000-0000-0000-0000-000000000000")
  -- Parse the actual command before choosing its configuration boundary. An
  -- actor/reason merely containing a command name must never change topology.
  let (args, _) = choose inspectionTopology rawArgs
  parsed <- case O.execParserPure O.defaultPrefs (O.info (parser <**> O.helper) (O.fullDesc <> O.progDesc "Kansoku compiled ClickHouse migrations and persistent maintenance sessions; legacy import is unsupported")) args of
    O.Success value -> pure value
    O.Failure failure -> case O.renderFailure failure "kansoku-ch-migrate" of
      (message, ExitSuccess) -> putStrLn message >> exitWith ExitSuccess
      _ -> Text.hPutStrLn stderr "Invalid migration arguments; use --help" >> exitFailure
    _ -> exitWith ExitSuccess
  topology <- case parsed of
    (_, _, _, RestoredCopy {}) -> pure inspectionTopology
    (_, _, _, RestoredExpectations {}) -> pure inspectionTopology
    _ -> Config.loadTopology True
  let (selectedArgs, compiled) = choose topology rawArgs
  unless (selectedArgs == args) (fail "Topology-dependent migration argument rewriting is unsupported")
  plan <- either (const (fail "Invalid compiled migration plan")) pure compiled
  case parsed of
    (_, _, recoveryFile, RestoredCopy format options) -> do
      (report, passed) <- Restored.inspect options plan recoveryFile
      renderMaintenance format "verify-restored" report
      unless passed exitFailure
    (_, _, _, RestoredExpectations format) -> Restored.expectations plan >>= renderMaintenance format "restored-expectations"
    (_, _, _, Native (Invocation _ AdoptCommand {})) -> Text.hPutStrLn stderr "Legacy import is unsupported; create a fresh owned stack." >> exitFailure
    (_, _, _, Native invocation@(Invocation _ PlanCommand)) -> execute plan Nothing Nothing invocation
    (predecessor, evidenceFile, recoveryFile, Native invocation@(Invocation format command)) -> do
      config <- Config.loadConfig
      case command of
        UpCommand (UpInput _ _ (Just initialization) _) -> unless (initialization == Config.ledger config) (fail "Initialization ledger differs from retained identity")
        _ -> pure ()
      if isMutation command || guarded command
        then do
          rawMutation <- if isMutation command then Just <$> entry config predecessor evidenceFile command else pure Nothing
          prepared <- case rawMutation of
            Just (n, _, audit) -> Just <$> Backup.prepare config plan (case command of RepairCommand {} -> True; _ -> False) n audit recoveryFile
            Nothing -> pure Nothing
          let mutation = case (rawMutation, prepared) of
                (Just (n, name, audit), Just recovery) -> Just (n, name, Backup.auditEvidence recovery audit)
                _ -> rawMutation
          withCoordinator config mutation $ \provider _ record requireReceipts -> do
            case command of UpCommand (UpInput _ _ (Just _) _) -> Config.ensureFreshInitialization config; _ -> pure ()
            case command of
              RepairCommand _ (RepairInput _ _ _ _ _ _ receipts) -> requireReceipts (map L.appendReceiptText receipts)
              _ -> pure ()
            case (mutation, prepared) of
              (Just (n, _, _), Just recovery) -> Backup.accept config plan n recovery
              _ -> pure ()
            mapM_ (\(_, _, audit) -> checkAuditDrain audit) mutation
            result <-
              handleCommand
                ( commandEnvironment
                    (Just (Config.nativeConfig config (firstUse command)))
                    (Just provider)
                    ( \event -> do
                        if Event.phase event == Event.BeforeSql then mapM_ (\(_, _, audit) -> checkAuditDrain audit) mutation else pure ()
                        sessionEvents config plan event
                    )
                    redactedDiagnostics
                    AdministrativeCommands
                )
                plan
                command
            -- Emit the native report before coordinator cleanup so a secondary
            -- PostgreSQL failure cannot hide the original primary error/receipt.
            outputSelected (Config.nativeConfig config False) format result
            if isMutation command then record (successful result) (pendingReceipts result) else pure ()
            unless (successful result) exitFailure
        else execute plan (Just (Config.nativeConfig config False)) Nothing invocation
    (predecessor, evidenceFile, _, Reconcile format expected input receipts) -> do
      config <- Config.loadConfig
      match config expected
      n <- requirePredecessor predecessor
      audit <- auditValue input >>= bindDrain config n evidenceFile
      withCoordinator config (Just (n, "maintenance-reconcile", audit)) $ \provider _ record requireReceipts -> do
        requireReceipts (map L.appendReceiptText receipts)
        checkAuditDrain audit
        classifications <- forM receipts $ \receipt -> do
          reconciled <- L.reconcileAppend (Config.nativeConfig config False) provider receipt
          case reconciled of
            L.LedgerCommandResult (Right (classification, _)) _ [] | classification /= L.Conflicting -> pure (Text.pack (show classification))
            _ -> fail "Receipt reconciliation failed; fence retained"
        observed <- I.status I.Observe (Config.nativeConfig config False) plan
        case observed of
          Right (R.InspectionReport (R.HistoryReport _ _ presence _ _ _ _ False) _ []) -> do
            case presence of R.LedgerMissing -> Config.ensureFreshInitialization config; R.LedgerUninitialized -> Config.ensureFreshInitialization config; R.LedgerInitializedAt _ -> pure (); _ -> fail "Unknown ledger state"
            record True []
          _ -> do
            renderMaintenance format "maintenance-reconcile" (A.object ["receipts" A..= classifications, "resolved" A..= False])
            Text.hPutStrLn stderr "Native history is unresolved or incompatible; use explicit repair. The fence remains active."
            exitFailure
        renderMaintenance format "maintenance-reconcile" (A.object ["receipts" A..= classifications, "resolved" A..= True])
    (_, _, _, RecoveryContext format) -> do
      config <- Config.loadConfig
      Backup.context config plan >>= renderMaintenance format "maintenance-recovery-context"
    (_, _, _, RecoveryObservation format) -> do
      config <- Config.loadConfig
      Rebind.observe config plan >>= renderMaintenance format "maintenance-recovery-observation"
    (_, evidenceFile, recoveryFile, RebindServer format expected old new original restored input) -> do
      config <- Config.loadConfig
      match config expected
      mapM_ (either (const (fail "Invalid explicit recovery server UUID")) (const (pure ())) . T.serverId) [old, new]
      drain <- maybe (fail "Fresh --drain-evidence FILE required for rebuilt-server recovery") pure evidenceFile
      manifest <- maybe (fail "Original --recovery-set FILE required for rebuilt-server recovery") pure recoveryFile
      audit <- auditValue input
      Rebind.rebind config plan old new manifest original restored drain audit >>= renderMaintenance format "maintenance-rebind"
    (_, _, _, SessionStatus format) -> do
      config <- Config.loadConfig
      let session = C.SessionIdentity (maybe "" id (Config.session config)) (T.targetKeyText (Config.target config)) (Config.sessionTarget config) (T.ledgerIdText (Config.ledger config))
      settings <- maybe (fail "PG_CONNECTION_STRING required") pure (Config.postgres config)
      row <- C.sessionStatus settings session
      whenNull row
      renderMaintenance format "maintenance-status" row
    (_, _, _, Begin format expected input) -> do
      config <- Config.loadConfig
      match config expected
      audit <- auditValue input
      settings <- maybe (fail "PG_CONNECTION_STRING required") pure (Config.postgres config)
      row <- C.beginSession settings (T.targetKeyText (Config.target config)) (Config.sessionTarget config) (T.ledgerIdText (Config.ledger config)) audit
      renderMaintenance format "maintenance-begin" row
    (predecessor, evidenceFile, _, Finish format expected input) -> do
      config <- Config.loadConfig
      match config expected
      n <- requirePredecessor predecessor
      audit <- auditValue input >>= bindDrain config n evidenceFile
      withCoordinator config (Just (n, "maintenance-finish", audit)) $ \_ finish _ requireReceipts -> do
        requireReceipts []
        checkAuditDrain audit
        verified <- I.verify I.Observe (Config.nativeConfig config False) (I.verifyOptions True) plan
        case verified of
          Left failure -> output format (CommandResult "maintenance-finish" (Left (InspectionFailed failure))) >> exitFailure
          Right _ -> verifySessions config plan >> checkAuditDrain audit >> finish
      renderMaintenance format "maintenance-finish" (A.object ["complete" A..= True])
  where
    whenNull row = unless (row /= A.Null) (fail "Unknown session identity")
    match config expected = unless (Config.target config == expected) (fail "Expected target mismatch")
    guarded = \case StatusCommand value -> value; HistoryCommand value -> value; VerifyCommand _ value -> value; _ -> False
    firstUse = \case UpCommand (UpInput _ _ initial _) -> isJust initial; _ -> False
    execute plan config provider (Invocation format command) = do
      result <- handleCommand (commandEnvironment config provider quietEvents redactedDiagnostics AdministrativeCommands) plan command
      case config of
        Nothing -> display (Invocation format command) result
        Just settings -> do
          outputSelected settings format result
          unless (successful result) exitFailure

entry :: Config.Config -> Maybe Integer -> Maybe FilePath -> Command -> IO (Integer, Text, A.Value)
entry config predecessor evidenceFile command = do
  quiet <- either (const (fail "Explicit target-bound quiescence evidence required")) pure (quiescenceForCommand (Config.target config) command)
  unless (isJust quiet) (fail "Explicit quiescence evidence required even before the first entry")
  n <- requirePredecessor predecessor
  input <- case command of UpCommand (UpInput _ a _ _) -> pure a; RepairCommand _ (RepairInput _ _ _ _ a _ _) -> pure a; _ -> fail "Unsupported mutation"
  evidence <- auditValue input >>= bindDrain config n evidenceFile
  pure (n, commandName command, evidence)

-- The evidence inventory is deployment configuration, not a claim supplied by
-- the attestation. The lease subsequently verifies the same session/predecessor
-- atomically before recording the native entry.
bindDrain :: Config.Config -> Integer -> Maybe FilePath -> A.Value -> IO A.Value
bindDrain _ _ Nothing _ = fail "Owner-bound --drain-evidence FILE required; persist the fence, establish external drain and bind its current predecessor"
bindDrain config predecessor (Just path) audit = do
  ident <- maybe (fail "KANSOKU_CH_MIGRATION_SESSION required") pure (Config.session config)
  settings <- maybe (fail "PG_CONNECTION_STRING required") pure (Config.postgres config)
  row <- C.sessionStatus settings (C.SessionIdentity ident (T.targetKeyText (Config.target config)) (Config.sessionTarget config) (T.ledgerIdText (Config.ledger config)))
  created <- case row of
    A.Object fields -> case KM.lookup "last_entry_at" fields of
      Just value -> case A.fromJSON value :: A.Result UTCTime of
        A.Success time -> pure time
        _ -> fail "Invalid persisted predecessor time"
      _ -> fail "Unknown persisted session"
    _ -> fail "Unknown persisted session"
  raw <- lookupEnv "KANSOKU_CH_DRAIN_SUBMITTERS" >>= maybe (fail "KANSOKU_CH_DRAIN_SUBMITTERS must declare every submitting principal as a JSON array") pure
  submitters <- either (const (fail "Invalid trusted drain submitter inventory")) pure (A.eitherDecodeStrict' (Encoding.encodeUtf8 (Text.pack raw)))
  let servers = case Config.sessionTarget config of
        C.DirectTarget sid -> [sid]
        C.ReplicatedTarget _ ids -> ids
      required = Drain.DrainRequirement (T.targetKeyText (Config.target config)) servers (Just (T.ledgerIdText (Config.ledger config))) ["analytics", "kansoku_migration_ledger"] (Config.username config : submitters) [Config.username config] (Drain.MigrationSession ident predecessor) created
  now <- getCurrentTime
  accepted <- Drain.readDrainEvidence now required path >>= either (fail . Text.unpack) pure
  case audit of
    A.Object fields -> pure (A.Object (KM.insert "predecessorState" (C.predecessorState row) (KM.insert "drainEvidenceSha256" (A.toJSON (Drain.acceptedDigest accepted)) (KM.insert "drainEvidence" (Drain.acceptedDocument accepted) fields))))
    _ -> fail "Invalid audit"

-- Recheck the already accepted, retained envelope after lease acquisition;
-- never reopen the operator's file or substitute a different audit document.
checkAuditDrain :: A.Value -> IO ()
checkAuditDrain (A.Object audit) = case KM.lookup "drainEvidence" audit of
  Nothing -> pure ()
  Just (A.Object evidence) -> case KM.lookup "expiresAt" evidence of
    Just expiry -> case A.fromJSON expiry :: A.Result UTCTime of
      A.Success time -> do
        now <- getCurrentTime
        unless (now < time) (fail "Drain evidence expired while waiting for exclusion; fence retained")
      _ -> fail "Invalid retained drain expiry"
    _ -> fail "Missing retained drain expiry"
  _ -> fail "Invalid retained drain envelope"
checkAuditDrain _ = fail "Invalid retained audit"

requirePredecessor :: Maybe Integer -> IO Integer
requirePredecessor (Just n) | n >= 0 = pure n
requirePredecessor _ = fail "A nonnegative --predecessor entry counter is required"

auditValue :: AuditInput -> IO A.Value
auditValue (AuditInput actor reason refs) = do
  _ <- either (const (fail "Invalid audit input")) pure (L.auditContext actor reason refs)
  pure (A.object ["actor" A..= actor, "reason" A..= reason, "references" A..= refs])

output :: OutputFormat -> CommandResult -> IO ()
output format result = do
  case format of
    JsonOutput -> BS.putStrLn (renderJson result)
    TextOutput -> Text.putStrLn (renderText result)
  unless (successful result) (Text.hPutStrLn stderr "ClickHouse migration command failed; retain its structured report and any pending receipts. The session fence remains authoritative.")

-- The pinned toolkit reports the observed server, but not the configured cluster.
-- Expose the full nonsecret selector on online JSON without changing offline plans.
outputSelected :: T.TargetConfig -> OutputFormat -> CommandResult -> IO ()
outputSelected settings JsonOutput result = do
  let selected = case T.configuredTopology settings of
        T.DirectServer sid -> A.object ["topology" A..= ("direct" :: Text), "serverId" A..= T.serverIdText sid]
        T.ReplicatedCluster name ids -> A.object ["topology" A..= ("replicated" :: Text), "cluster" A..= T.clusterNameText name, "replicaIds" A..= map T.serverIdText (NE.toList ids)]
  case A.eitherDecodeStrict' (renderJson result) of
    Right (A.Object row) -> LBS.putStrLn (A.encode (A.Object (KM.insert "selectedTarget" selected row)))
    _ -> fail "Invalid native JSON report"
  unless (successful result) (Text.hPutStrLn stderr "ClickHouse migration command failed; retain its structured report and any pending receipts. The session fence remains authoritative.")
outputSelected _ format result = output format result

renderMaintenance :: OutputFormat -> Text -> A.Value -> IO ()
renderMaintenance format command row = case format of
  JsonOutput -> LBS.putStrLn (A.encode (A.object ["schemaVersion" A..= (1 :: Int), "command" A..= command, "result" A..= row]))
  TextOutput -> LBS.putStrLn (A.encode row)

successful :: CommandResult -> Bool
successful (CommandResult _ (Right _)) = True
successful _ = False

display :: Invocation -> CommandResult -> IO ()
display (Invocation format _) result = do
  output format result
  unless (successful result) exitFailure

pendingReceipts :: CommandResult -> [Text]
pendingReceipts (CommandResult _ (Left (RunFailed (R.RunFailure primary _ secondary)))) =
  receipt primary ++ concat [receipt problem | R.RecordingError problem <- secondary]
  where
    receipt (R.LedgerRequestFailed _ _ (Just value)) = [L.appendReceiptText value]
    receipt _ = []
pendingReceipts _ = []
