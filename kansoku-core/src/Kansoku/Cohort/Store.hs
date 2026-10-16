-- | Account-scoped definitions; names conflict without overwriting another record.
module Kansoku.Cohort.Store where

import Data.Aeson qualified as A
import Data.Generics.Labels ()
import Data.Text qualified
import Data.UUID (UUID)
import Hasql.Decoders qualified as D
import Hasql.DynamicStatements.Snippet qualified as S
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kansoku.Cohort.Types
import Kansoku.Event (AccountId (..))
import Kansoku.Prelude
import Relay.Pagination
import Relay.Pagination.Hasql

cohortRow :: D.Row Cohort
cohortRow = Cohort <$> col D.uuid <*> col (D.refine decodeDefinition D.jsonb) <*> col D.timestamptz <*> col D.timestamptz
  where
    col decoder = D.column (D.nonNullable decoder)
    decodeDefinition value = case A.fromJSON value of A.Success x -> Right x; A.Error e -> Left (Data.Text.pack e)

cohortSort :: SortSpec Cohort
cohortSort = SortSpec (KeyColumn "id" Asc (view #id) uuidKey :| [])

statement :: Text -> Statement.Statement A.Value (Maybe Cohort)
statement sql = Statement.preparable sql (E.param (E.nonNullable E.jsonb)) (D.rowMaybe cohortRow)

loadCohort :: Pool.Pool -> AccountId -> UUID -> IO (Either Pool.UsageError (Maybe Cohort))
loadCohort pool account ident = Pool.use pool (Session.statement (params account ident) (statement "SELECT id,definition,created_at,updated_at FROM kansoku.cohorts WHERE account_id=$1->>'account' AND id=($1->>'id')::uuid"))

params :: AccountId -> UUID -> A.Value
params (AccountId account) ident = A.object ["account" A..= account, "id" A..= ident]

saveCohort :: Pool.Pool -> AccountId -> Maybe UUID -> CohortDefinition -> IO (Either Pool.UsageError (Maybe Cohort))
saveCohort pool account ident definition = Pool.use pool $ Session.statement payload $ statement sql
  where
    payload = A.object ["account" A..= unAccountId account, "id" A..= ident, "definition" A..= definition, "name" A..= name definition, "kind" A..= kind definition]
    sql = case ident of
      Nothing -> "INSERT INTO kansoku.cohorts(account_id,name,kind,definition) VALUES($1->>'account',$1->>'name',$1->>'kind',$1->'definition') ON CONFLICT(account_id,name) DO NOTHING RETURNING id,definition,created_at,updated_at"
      Just _ -> "UPDATE kansoku.cohorts SET name=$1->>'name',definition=$1->'definition',updated_at=now() WHERE account_id=$1->>'account' AND id=($1->>'id')::uuid AND kind=$1->>'kind' AND NOT EXISTS(SELECT 1 FROM kansoku.cohorts c WHERE c.account_id=$1->>'account' AND c.name=$1->>'name' AND c.id<>($1->>'id')::uuid) RETURNING id,definition,created_at,updated_at"

deleteDefinition :: Pool.Pool -> AccountId -> UUID -> IO (Either Pool.UsageError (Maybe Cohort))
deleteDefinition pool account ident = Pool.use pool $ Session.statement (params account ident) (statement "DELETE FROM kansoku.cohorts WHERE account_id=$1->>'account' AND id=($1->>'id')::uuid RETURNING id,definition,created_at,updated_at")

listDefinitions :: Pool.Pool -> AccountId -> PageRequest -> IO (Either (Either CursorError Pool.UsageError) (Connection Cohort))
listDefinitions pool (AccountId account) page = case paginate cohortSort page base cohortRow of
  Left e -> pure (Left (Left e))
  Right stmt -> either (Left . Right) Right <$> Pool.use pool (Session.statement () stmt)
  where
    base = S.sql "SELECT id,definition,created_at,updated_at FROM kansoku.cohorts WHERE account_id=" <> S.encoderAndParam (E.nonNullable E.text) account
