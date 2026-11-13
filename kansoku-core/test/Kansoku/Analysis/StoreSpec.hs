module Kansoku.Analysis.StoreSpec (spec, withStore, validInput, stored) where

import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, readMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (concurrently)
import Control.Exception (AsyncException (ThreadKilled), bracket, finally, try)
import Control.Monad (forM, forM_)
import Data.Aeson qualified as A
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate.Test (withMigratedDatabase)
import Hasql.Connection qualified as C
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as S
import Hasql.Statement qualified as St
import Kansoku.Analysis.Store qualified as Store
import Kansoku.Analysis.Types
import Kansoku.Analysis.Validation
import Kansoku.Event (AccountId (..))
import Kansoku.Migrations (kansokuMigrationPlan)
import Kansoku.Postgres (createPool)
import Kansoku.Postgres.Direct
import Kansoku.Prelude
import Relay.Pagination qualified as R
import System.Timeout (timeout)
import Test.Hspec

validInput :: AnalysisInput
validInput = AnalysisInput "  日本語 😀  " Nothing Trends 999999999999999999999999 (A.object ["nested" A..= A.object ["zero" A..= ("\0" :: Text), "values" A..= [A.Null, A.Bool True, A.Number 1.25]]])

stored :: (Show a) => Store.StoreResult a -> IO a
stored (Store.Stored x) = pure x
stored x = fail (show x)

withStore :: (Text -> Pool.Pool -> IO ()) -> IO ()
withStore action = do
  plan <- either (fail . show) pure kansokuMigrationPlan
  result <- withMigratedDatabase plan $ \connection -> do
    let col = D.column (D.nonNullable D.text)
    info <- C.use connection (S.statement () (St.preparable "SELECT current_setting('unix_socket_directories'),current_setting('port'),current_user::text,current_database()::text" E.noParams (D.singleRow ((,,,) <$> col <*> col <*> col <*> col)))) >>= either (fail . show) pure
    let (socket, port, user, database) = info
        settings = "host=" <> socket <> " port=" <> port <> " user=" <> user <> " dbname=" <> database
    bracket (createPool settings) Pool.release (action settings)
  either (fail . show) pure result

spec :: Spec
spec = describe "Kansoku.Analysis.Store" $ do
  it "preserves opaque JSON and account isolation, revisions and timestamps" $ withStore $ \settings pool -> do
    value <- either (fail . show) pure (validateAnalysis validInput)
    first <- Store.createAnalysis settings 2 (AccountId "a") value >>= stored
    let ident = first ^. #id
    first ^. #document `shouldBe` validInput ^. #document
    first ^. #name `shouldBe` "日本語 😀"
    Store.loadAnalysis pool (AccountId "a") ident `shouldReturn` Store.Stored first
    Store.loadAnalysis pool (AccountId "b") ident `shouldReturn` Store.Missing
    Store.replaceAnalysis settings (AccountId "b") ident (Revision 1) value `shouldReturn` Store.Missing
    Store.deleteAnalysis settings (AccountId "b") ident (Revision 1) `shouldReturn` Store.Missing
    second <- Store.replaceAnalysis settings (AccountId "a") ident (Revision 1) value >>= stored
    second ^. #revision `shouldBe` Revision 2
    second ^. #createdAt `shouldBe` first ^. #createdAt
    second ^. #updatedAt `shouldSatisfy` (> first ^. #updatedAt)
    Store.replaceAnalysis settings (AccountId "a") ident (Revision 1) value `shouldReturn` Store.Stale
    Store.deleteAnalysis settings (AccountId "a") ident (Revision 1) `shouldReturn` Store.Stale
    Store.loadAnalysis pool (AccountId "a") ident `shouldReturn` Store.Stored second
    Store.deleteAnalysis settings (AccountId "a") ident (Revision 2) `shouldReturn` Store.Stored True
    Store.deleteAnalysis settings (AccountId "a") ident (Revision 2) `shouldReturn` Store.Missing

  it "admits one winner through independent simultaneous update connections" $ withStore $ \settings _ -> do
    value <- either (fail . show) pure (validateAnalysis validInput)
    first <- Store.createAnalysis settings 2 (AccountId "a") value >>= stored
    results <- racePair (Store.replaceAnalysis settings (AccountId "a") (first ^. #id) (Revision 1) value)
    length [() | Store.Stored _ <- results] `shouldBe` 1
    length [() | Store.Stale <- results] `shouldBe` 1

  it "serializes concurrent creates at the quota and permits edits after lowering it" $ withStore $ \settings _ -> do
    value <- either (fail . show) pure (validateAnalysis validInput)
    first <- Store.createAnalysis settings 2 (AccountId "a") value >>= stored
    results <- racePair (Store.createAnalysis settings 2 (AccountId "a") value)
    length [() | Store.Stored _ <- results] `shouldBe` 1
    length [() | Store.LimitReached <- results] `shouldBe` 1
    Store.createAnalysis settings 1 (AccountId "a") value `shouldReturn` Store.LimitReached
    _ <- Store.replaceAnalysis settings (AccountId "a") (first ^. #id) (Revision 1) value >>= stored
    _ <- Store.createAnalysis settings 2 (AccountId "b") value >>= stored
    Store.deleteAnalysis settings (AccountId "a") (first ^. #id) (Revision 2) `shouldReturn` Store.Stored True
    _ <- Store.createAnalysis settings 2 (AccountId "a") value >>= stored
    pure ()

  it "propagates cancellation while waiting for an account lock and releases its session" $ withStore $ \settings _ -> do
    value <- either (fail . show) pure (validateAnalysis validInput)
    withPostgres settings $ \connection -> do
      void $ pg connection "SELECT to_jsonb(pg_advisory_lock(hashtextextended($1->>'key',0)))" (A.object ["key" A..= ("kansoku:analyses:a" :: Text)])
      done <- newEmptyMVar
      worker <- forkIO $ do
        result <- try (Store.createAnalysis settings 2 (AccountId "a") value)
        putMVar done (result :: Either AsyncException (Store.StoreResult SavedAnalysis))
      let awaitWaiter 0 = fail "writer never waited for account lock"
          awaitWaiter attempts = do
            count <- pg connection "SELECT to_jsonb(count(*)) FROM pg_stat_activity WHERE datname=current_database() AND wait_event='advisory'" A.Null
            if count == A.Number 1 then pure () else threadDelay 10000 >> awaitWaiter (attempts - 1)
      ( do
          awaitWaiter (200 :: Int)
          killThread worker
          timeout 5000000 (takeMVar done) `shouldReturn` Just (Left ThreadKilled)
        )
        `finally` killThread worker
    result <- timeout 5000000 (Store.createAnalysis settings 2 (AccountId "a") value)
    case result of
      Just (Store.Stored _) -> pure ()
      other -> expectationFailure ("cancelled session retained lock: " <> show other)

  it "checks bigint exhaustion without wrapping or changing the resource" $ withStore $ \settings pool -> do
    value <- either (fail . show) pure (validateAnalysis validInput)
    first <- Store.createAnalysis settings 2 (AccountId "a") value >>= stored
    withPostgres settings $ \connection -> pgScript connection "UPDATE kansoku.analyses SET revision=9223372036854775807 WHERE account_id='a'"
    before <- Store.loadAnalysis pool (AccountId "a") (first ^. #id) >>= stored
    Store.replaceAnalysis settings (AccountId "a") (first ^. #id) (Revision maxBound) value `shouldReturn` Store.StoreUnavailable
    Store.loadAnalysis pool (AccountId "a") (first ^. #id) `shouldReturn` Store.Stored before
    Store.deleteAnalysis settings (AccountId "a") (first ^. #id) (Revision maxBound) `shouldReturn` Store.Stored True

  it "walks both directions with equal microsecond timestamps, filters and deleted cursor rows" $ withStore $ \settings pool -> do
    values <- forM [Trends, Funnel, Retention, Funnel] $ \kind -> do
      validated <- either (fail . show) pure (validateAnalysis (validInput & #kind .~ kind))
      Store.createAnalysis settings 10 (AccountId "a") validated >>= stored
    withPostgres settings $ \connection -> pgScript connection "UPDATE kansoku.analyses SET updated_at='2026-01-01T00:00:00.123456Z' WHERE account_id='a'"
    let ordered = sortOn (view #id) values
        ids = map (view #id)
        page kind request = Store.listAnalyses pool (AccountId "a") kind request >>= either (fail . show) pure
        walk kind backward cursor = do
          connection <- page kind (if backward then R.PageRequest 1 R.Backward cursor else R.PageRequest 1 R.Forward cursor)
          let edges = R.edges connection
          case edges of
            [] -> pure []
            [edge] -> do
              rest <- walk kind backward (Just (edge ^. #cursor))
              pure (if backward then rest <> [R.node edge] else R.node edge : rest)
            _ -> fail "unexpected page size"
    forM_ [Nothing, Just Funnel] $ \kind -> do
      let expected = maybe ordered (\k -> filter ((== k) . view #kind) ordered) kind
      beginning <- page kind (R.PageRequest 1 R.Forward Nothing)
      ending <- page kind (R.PageRequest 1 R.Backward Nothing)
      beginning ^. #pageInfo . #hasPreviousPage `shouldBe` False
      beginning ^. #pageInfo . #hasNextPage `shouldBe` True
      ending ^. #pageInfo . #hasPreviousPage `shouldBe` True
      ending ^. #pageInfo . #hasNextPage `shouldBe` False
      ids <$> walk kind False Nothing `shouldReturn` ids expected
      ids <$> walk kind True Nothing `shouldReturn` ids expected
    firstPage <- page Nothing (R.PageRequest 1 R.Forward Nothing)
    let edge = head (R.edges firstPage)
    Store.deleteAnalysis settings (AccountId "a") (R.node edge ^. #id) (Revision 1) `shouldReturn` Store.Stored True
    nextPage <- page Nothing (R.PageRequest 1 R.Forward (Just (edge ^. #cursor)))
    ids (map R.node (R.edges nextPage)) `shouldBe` take 1 (drop 1 (ids ordered))
    value <- either (fail . show) pure (validateAnalysis validInput)
    changed <- Store.replaceAnalysis settings (AccountId "a") (last ordered ^. #id) (Revision 1) value >>= stored
    latest <- page Nothing (R.PageRequest 1 R.Forward Nothing)
    ids (map R.node (R.edges latest)) `shouldBe` [changed ^. #id]

racePair :: IO a -> IO [a]
racePair action = do
  gate <- newEmptyMVar
  let ready = readMVar gate >> action
  putMVar gate ()
  (a, b) <- concurrently ready ready
  pure [a, b]
