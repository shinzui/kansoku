-- | Account-scoped current reads and serialized, revision-checked mutations.
module Kansoku.Analysis.Store where

import Control.Exception (onException)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.UUID (UUID)
import Database.PostgreSQL.LibPQ qualified as PQ
import Hasql.Decoders qualified as D
import Hasql.DynamicStatements.Snippet qualified as S
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kansoku.Analysis.Types
import Kansoku.Analysis.Validation
import Kansoku.Event (AccountId (..))
import Kansoku.Exception (trySynchronous)
import Kansoku.Postgres.Direct
import Kansoku.Prelude
import Relay.Pagination
import Relay.Pagination.Hasql
import Text.Read (readMaybe)

data StoreResult a = Stored a | Missing | Stale | LimitReached | StoreUnavailable
  deriving stock (Eq, Show)

columns :: Text
columns = "id,name,description,kind,document_version::text,document_text,revision,created_at,updated_at"

analysisRow :: D.Row SavedAnalysis
analysisRow = SavedAnalysis <$> col D.uuid <*> col D.text <*> D.column (D.nullable D.text) <*> col (D.refine parseUrlKind D.text) <*> col (D.refine integer D.text) <*> col (D.refine json D.text) <*> (Revision <$> col D.int8) <*> col D.timestamptz <*> col D.timestamptz
  where
    col decoder = D.column (D.nonNullable decoder)
    parseUrlKind raw = case raw of "trends" -> Right Trends; "funnel" -> Right Funnel; "retention" -> Right Retention; _ -> Left "invalid stored kind"
    integer raw = maybe (Left "invalid stored documentVersion") Right (readMaybe (Text.unpack raw))
    json = either (const (Left "invalid stored document")) Right . A.eitherDecodeStrict' . Text.encodeUtf8

loadAnalysis :: Pool.Pool -> AccountId -> UUID -> IO (StoreResult SavedAnalysis)
loadAnalysis pool account ident = do
  result <-
    Pool.use pool $
      Session.statement (identityParams account ident) $
        Statement.preparable
          ("SELECT " <> columns <> " FROM kansoku.analyses WHERE account_id=$1->>'account' AND id=($1->>'id')::uuid")
          (E.param (E.nonNullable E.jsonb))
          (D.rowMaybe analysisRow)
  pure $ case result of Left _ -> StoreUnavailable; Right Nothing -> Missing; Right (Just x) -> Stored x

analysisSort :: SortSpec SavedAnalysis
analysisSort = SortSpec (KeyColumn "updated_at" Desc (view #updatedAt) timestamptzKey :| [KeyColumn "id" Asc (view #id) uuidKey])

listAnalyses :: Pool.Pool -> AccountId -> Maybe AnalysisKind -> PageRequest -> IO (Either (Either CursorError Pool.UsageError) (Connection SavedAnalysis))
listAnalyses pool (AccountId account) kind page = case paginate analysisSort page base analysisRow of
  Left err -> pure (Left (Left err))
  Right stmt -> either (Left . Right) Right <$> Pool.use pool (Session.statement () stmt)
  where
    base =
      S.sql ("SELECT " <> columns <> " FROM kansoku.analyses WHERE account_id=")
        <> S.encoderAndParam (E.nonNullable E.text) account
        <> maybe mempty (\k -> S.sql " AND kind=" <> S.encoderAndParam (E.nonNullable E.text) (kindText k)) kind

identityParams :: AccountId -> UUID -> A.Value
identityParams (AccountId account) ident = A.object ["account" A..= account, "id" A..= ident]

-- The document is always a JSON string in the transport parameter and SQL
-- projection. Neither PostgreSQL nor its JSONB parameter codec parses its content.
savedProjection :: Text
savedProjection = "id,name,description,kind,document_version AS \"documentVersion\",document_text AS document,revision,created_at AS \"createdAt\",updated_at AS \"updatedAt\""

decodeSaved :: A.Value -> IO SavedAnalysis
decodeSaved value =
  either (const (fail "invalid saved analysis projection")) pure $
    parseEither
      ( A.withObject "saved analysis" $ \o -> do
          encoded <- o A..: "document"
          document <- either (const (fail "invalid stored document")) pure (A.eitherDecodeStrict' (Text.encodeUtf8 encoded))
          A.parseJSON (A.Object (KM.insert "document" document o))
      )
      value

-- Separate lock statement is essential: subsequent READ COMMITTED statements
-- see commits made by the prior lock holder, even when this session waited.
mutate :: Text -> AccountId -> (PQ.Connection -> IO (StoreResult a)) -> IO (StoreResult a)
mutate settings (AccountId account) action = do
  result <- trySynchronous $ withPostgres settings $ \connection -> do
    pgScript connection "BEGIN ISOLATION LEVEL READ COMMITTED"
    -- A cancelled in-flight query may prevent sending ROLLBACK. Keep the
    -- original exception; closing the bracketed connection also rolls back.
    let rollback = void (trySynchronous (pgScript connection "ROLLBACK"))
    ( do
        void $ pg connection "SELECT to_jsonb(pg_advisory_xact_lock(hashtextextended($1->>'key',0)))" (A.object ["key" A..= ("kansoku:analyses:" <> account)])
        outcome <- action connection
        pgScript connection "COMMIT"
        pure outcome
      )
      `onException` rollback
  pure (either (const StoreUnavailable) (\x -> x) result)

createAnalysis :: Text -> Int -> AccountId -> ValidatedAnalysis -> IO (StoreResult SavedAnalysis)
createAnalysis settings limit account validated = mutate settings account $ \connection -> do
  count <- pg connection "SELECT to_jsonb(count(*)) FROM kansoku.analyses WHERE account_id=$1->>'account'" (A.object ["account" A..= unAccountId account])
  case A.fromJSON count of
    A.Success (n :: Int64) | n >= fromIntegral limit -> pure LimitReached
    A.Success (_ :: Int64) -> do
      result <- pg connection (Text.encodeUtf8 ("WITH saved AS (INSERT INTO kansoku.analyses(account_id,name,description,kind,document_version,document_text) VALUES($1->>'account',$1->>'name',$1->>'description',$1->>'kind',($1->>'documentVersion')::numeric,$1->>'document') RETURNING *) SELECT row_to_json(t) FROM (SELECT " <> savedProjection <> " FROM saved) t")) (writeParams account validated)
      Stored <$> decodeSaved result
    A.Error _ -> fail "invalid analysis count"

writeParams :: AccountId -> ValidatedAnalysis -> A.Value
writeParams account (ValidatedAnalysis AnalysisInput {name, description, kind, documentVersion} documentText) =
  A.object
    ["account" A..= unAccountId account, "name" A..= name, "description" A..= description, "kind" A..= kind, "documentVersion" A..= show documentVersion, "document" A..= documentText]

replaceAnalysis :: Text -> AccountId -> UUID -> Revision -> ValidatedAnalysis -> IO (StoreResult SavedAnalysis)
replaceAnalysis settings account ident expected validated = mutate settings account $ \connection ->
  checkRevision connection account ident expected $ do
    when (unRevision expected == maxBound) (fail "analysis revision exhausted")
    let A.Object fields = writeParams account validated
        payload = A.Object (KM.insert "id" (toJSON ident) (KM.insert "revision" (toJSON expected) fields))
    result <- pg connection (Text.encodeUtf8 ("WITH saved AS (UPDATE kansoku.analyses SET name=$1->>'name',description=$1->>'description',kind=$1->>'kind',document_version=($1->>'documentVersion')::numeric,document_text=$1->>'document',revision=revision+1,updated_at=greatest(clock_timestamp(),updated_at+interval '1 microsecond') WHERE account_id=$1->>'account' AND id=($1->>'id')::uuid AND revision=($1->>'revision')::bigint RETURNING *) SELECT row_to_json(t) FROM (SELECT " <> savedProjection <> " FROM saved) t")) payload
    Stored <$> decodeSaved result

deleteAnalysis :: Text -> AccountId -> UUID -> Revision -> IO (StoreResult Bool)
deleteAnalysis settings account ident expected = mutate settings account $ \connection ->
  checkRevision connection account ident expected $ do
    let A.Object fields = identityParams account ident
    result <- pg connection "WITH deleted AS (DELETE FROM kansoku.analyses WHERE account_id=$1->>'account' AND id=($1->>'id')::uuid AND revision=($1->>'revision')::bigint RETURNING id) SELECT to_jsonb(count(*)=1) FROM deleted" (A.Object (KM.insert "revision" (toJSON expected) fields))
    if result == A.Bool True then pure (Stored True) else fail "analysis deletion invariant"

checkRevision :: PQ.Connection -> AccountId -> UUID -> Revision -> IO (StoreResult a) -> IO (StoreResult a)
checkRevision connection account ident expected action = do
  result <- pg connection "SELECT to_jsonb(revision) FROM kansoku.analyses WHERE account_id=$1->>'account' AND id=($1->>'id')::uuid" (identityParams account ident)
  if result == A.Null
    then pure Missing
    else case A.fromJSON result of
      A.Success actual | actual == expected -> action
      A.Success (_ :: Revision) -> pure Stale
      A.Error _ -> fail "invalid analysis revision"
