module Kansoku.ClickHouseMigration.Command (mainWith) where

import ClickHouseMigrate.CLI
import ClickHouseMigrate.Error (PlanError)
import ClickHouseMigrate.Event (quietEvents, redactedDiagnostics)
import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Plan (MigrationPlan)
import ClickHouseMigrate.Report qualified as R
import ClickHouseMigrate.Target qualified as T
import Control.Applicative (many, optional, some, (<**>), (<|>))
import Control.Exception (IOException, fromException)
import Control.Monad (forM, unless)
import Data.Aeson qualified as A
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Kansoku.Admin.Coordination qualified as C
import Kansoku.ClickHouseMigration.Config qualified as Config
import Kansoku.ClickHouseMigration.Coordinator (withCoordinator)

import Kansoku.Exception (trySynchronous)
import Options.Applicative qualified as O
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (stderr)
import System.IO.Error (ioeGetErrorString, isUserError)

data ApplicationCommand = Native !Invocation | Begin !OutputFormat !T.TargetKey !AuditInput | Finish !OutputFormat !T.TargetKey !AuditInput | SessionStatus !OutputFormat | Reconcile !OutputFormat !T.TargetKey !AuditInput ![L.AppendReceipt]

-- The toolkit parser remains authoritative for its command syntax. The outer
-- option binds quiescence to a specific persisted application session entry.
parser :: O.Parser (Maybe Integer, ApplicationCommand)
parser = (,) <$> optional (O.option O.auto (O.long "predecessor" <> O.metavar "ENTRY" <> O.help "Quiescence evidence applies to this exact session entry counter")) <*> (Native <$> commandParser <|> maintenance)
  where
    maintenance = O.hsubparser (O.command "maintenance" (O.info commands (O.progDesc "Persist or finish a fenced administrative session")))
    receipts = many (O.option (O.eitherReader (either (const (Left "Invalid append receipt")) Right . L.parseAppendReceipt . Text.pack)) (O.long "pending-append" <> O.metavar "RECEIPT"))
    quietAudit = O.flag' () (O.long "quiescent" <> O.help "Submitting clients stopped and every predecessor request drained") *> audit True
    commands =
      O.hsubparser
        ( O.command "reconcile" (O.info (Reconcile <$> format <*> expected <*> quietAudit <*> receipts <**> O.helper) (O.progDesc "Reconcile retained receipts read-only under exclusion; acknowledge only compatible, resolved history"))
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

mainWith :: ([String] -> ([String], Either PlanError MigrationPlan)) -> IO ()
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

run :: ([String] -> ([String], Either PlanError MigrationPlan)) -> IO ()
run choose = do
  rawArgs <- getArgs
  let (args, compiled) = choose rawArgs
  parsed <- case O.execParserPure O.defaultPrefs (O.info (parser <**> O.helper) (O.fullDesc <> O.progDesc "Kansoku compiled ClickHouse migrations and persistent maintenance sessions; legacy import is unsupported")) args of
    O.Success value -> pure value
    O.Failure failure -> case O.renderFailure failure "kansoku-ch-migrate" of
      (message, ExitSuccess) -> putStrLn message >> exitWith ExitSuccess
      _ -> Text.hPutStrLn stderr "Invalid migration arguments; use --help" >> exitFailure
    _ -> exitWith ExitSuccess
  plan <- either (const (fail "Invalid compiled migration plan")) pure compiled
  case parsed of
    (_, Native (Invocation _ AdoptCommand {})) -> Text.hPutStrLn stderr "Legacy import is unsupported; create a fresh owned stack." >> exitFailure
    (_, Native invocation@(Invocation _ PlanCommand)) -> execute plan Nothing Nothing invocation
    (predecessor, Native invocation@(Invocation format command)) -> do
      config <- Config.loadConfig
      case command of
        UpCommand (UpInput _ _ (Just initialization) _) -> unless (initialization == Config.ledger config) (fail "Initialization ledger differs from retained identity")
        _ -> pure ()
      if isMutation command || guarded command
        then do
          mutation <- if isMutation command then Just <$> entry config predecessor command else pure Nothing
          withCoordinator config mutation $ \provider _ record requireReceipts -> do
            case command of UpCommand (UpInput _ _ (Just _) _) -> Config.ensureFreshInitialization config; _ -> pure ()
            case command of
              RepairCommand _ (RepairInput _ _ _ _ _ _ receipts) -> requireReceipts (map L.appendReceiptText receipts)
              _ -> pure ()
            result <- handleCommand (commandEnvironment (Just (Config.nativeConfig config (firstUse command))) (Just provider) quietEvents redactedDiagnostics AdministrativeCommands) plan command
            -- Emit the native report before coordinator cleanup so a secondary
            -- PostgreSQL failure cannot hide the original primary error/receipt.
            output format result
            if isMutation command then record (successful result) (pendingReceipts result) else pure ()
            unless (successful result) exitFailure
        else execute plan (Just (Config.nativeConfig config False)) Nothing invocation
    (predecessor, Reconcile format expected input receipts) -> do
      config <- Config.loadConfig
      match config expected
      audit <- auditValue input
      n <- requirePredecessor predecessor
      withCoordinator config (Just (n, "maintenance-reconcile", audit)) $ \provider _ record requireReceipts -> do
        requireReceipts (map L.appendReceiptText receipts)
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
    (_, SessionStatus format) -> do
      config <- Config.loadConfig
      let session = C.SessionIdentity (maybe "" id (Config.session config)) (T.targetKeyText (Config.target config)) (T.serverIdText (Config.server config)) (T.ledgerIdText (Config.ledger config))
      settings <- maybe (fail "PG_CONNECTION_STRING required") pure (Config.postgres config)
      row <- C.sessionStatus settings session
      whenNull row
      renderMaintenance format "maintenance-status" row
    (_, Begin format expected input) -> do
      config <- Config.loadConfig
      match config expected
      audit <- auditValue input
      settings <- maybe (fail "PG_CONNECTION_STRING required") pure (Config.postgres config)
      row <- C.beginSession settings (T.targetKeyText (Config.target config)) (T.serverIdText (Config.server config)) (T.ledgerIdText (Config.ledger config)) audit
      renderMaintenance format "maintenance-begin" row
    (predecessor, Finish format expected input) -> do
      config <- Config.loadConfig
      match config expected
      audit <- auditValue input
      n <- requirePredecessor predecessor
      withCoordinator config (Just (n, "maintenance-finish", audit)) $ \_ finish _ requireReceipts -> do
        requireReceipts []
        verified <- I.verify I.Observe (Config.nativeConfig config False) (I.verifyOptions True) plan
        case verified of
          Left failure -> output format (CommandResult "maintenance-finish" (Left (InspectionFailed failure))) >> exitFailure
          Right _ -> finish
      renderMaintenance format "maintenance-finish" (A.object ["complete" A..= True])
  where
    whenNull row = unless (row /= A.Null) (fail "Unknown session identity")
    match config expected = unless (Config.target config == expected) (fail "Expected target mismatch")
    guarded = \case StatusCommand value -> value; HistoryCommand value -> value; VerifyCommand _ value -> value; _ -> False
    firstUse = \case UpCommand (UpInput _ _ initial _) -> isJust initial; _ -> False
    execute plan config provider (Invocation format command) = do
      result <- handleCommand (commandEnvironment config provider quietEvents redactedDiagnostics AdministrativeCommands) plan command
      display (Invocation format command) result

entry :: Config.Config -> Maybe Integer -> Command -> IO (Integer, Text, A.Value)
entry config predecessor command = do
  quiet <- either (const (fail "Explicit target-bound quiescence evidence required")) pure (quiescenceForCommand (Config.target config) command)
  unless (isJust quiet) (fail "Explicit quiescence evidence required even before the first entry")
  n <- requirePredecessor predecessor
  input <- case command of UpCommand (UpInput _ a _ _) -> pure a; RepairCommand _ (RepairInput _ _ _ _ a _ _) -> pure a; _ -> fail "Unsupported mutation"
  evidence <- auditValue input
  pure (n, commandName command, evidence)

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
