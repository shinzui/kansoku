-- | Bounded nonblocking PostgreSQL sessions for cross-store maintenance locks.
module Kansoku.Postgres.Direct (openPostgres, closePostgres, withPostgres, pg, pgScript) where

import Control.Concurrent (threadWaitRead, threadWaitWrite)
import Control.Exception (bracket, bracketOnError)
import Data.Aeson qualified as A
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text.Encoding qualified as Text
import Database.PostgreSQL.LibPQ qualified as PQ
import Kansoku.Prelude
import System.Timeout (timeout)

withPostgres :: Text -> (PQ.Connection -> IO a) -> IO a
withPostgres settings = bracket (openPostgres settings) closePostgres

closePostgres :: PQ.Connection -> IO ()
closePostgres = PQ.finish

openPostgres :: Text -> IO PQ.Connection
openPostgres settings = bracketOnError (PQ.connectStart (Text.encodeUtf8 settings)) PQ.finish $ \connection -> do
  ready <- timeout 3_000_000 $ do
    connected <- connect connection PQ.PollingWriting
    unless connected (fail "maintenance PostgreSQL connection unavailable")
    enabled <- PQ.setnonblocking connection True
    unless enabled (fail "maintenance PostgreSQL nonblocking connection unavailable")
    pgScript connection "SET client_encoding TO 'UTF8'"
    pgScript connection "SET statement_timeout='60s'"
  unless (ready == Just ()) (fail "maintenance PostgreSQL connection unavailable")
  pure connection

-- | One JSONB parameter and one JSON result column. Errors never echo SQL or values.
pg :: PQ.Connection -> ByteString -> A.Value -> IO A.Value
pg connection sql value = run connection sql [Just (PQ.Oid 3802, LBS.toStrict (A.encode value), PQ.Text)]

pgScript :: PQ.Connection -> ByteString -> IO ()
pgScript connection sql = void (run connection sql [])

run :: PQ.Connection -> ByteString -> [Maybe (PQ.Oid, ByteString, PQ.Format)] -> IO A.Value
run connection sql params = do
  result <- timeout 65_000_000 $ do
    sent <- PQ.sendQueryParams connection sql params PQ.Text
    unless sent unavailable
    flush connection
    results A.Null
  maybe unavailable pure result
  where
    unavailable = fail "maintenance PostgreSQL command failed; fence remains until verified recovery"
    results previous = do
      waitResult connection
      PQ.getResult connection >>= \case
        Nothing -> pure previous
        Just result -> do
          status <- PQ.resultStatus result
          value <- case status of
            PQ.CommandOk -> pure previous
            PQ.TuplesOk -> do
              count <- PQ.ntuples result
              if count == 0
                then pure A.Null
                else do
                  bytes <- PQ.getvalue result 0 0
                  maybe (pure A.Null) (either (const unavailable) pure . A.eitherDecodeStrict') bytes
            _ -> unavailable
          PQ.unsafeFreeResult result
          results value

connect :: PQ.Connection -> PQ.PollingStatus -> IO Bool
connect connection = \case
  PQ.PollingOk -> pure True
  PQ.PollingFailed -> pure False
  polling -> do
    fd <- PQ.socket connection >>= maybe (fail "PostgreSQL socket unavailable") pure
    (if polling == PQ.PollingReading then threadWaitRead else threadWaitWrite) fd
    PQ.connectPoll connection >>= connect connection

flush :: PQ.Connection -> IO ()
flush connection =
  PQ.flush connection >>= \case
    PQ.FlushOk -> pure ()
    PQ.FlushFailed -> fail "PostgreSQL flush failed"
    PQ.FlushWriting -> do
      void (PQ.consumeInput connection)
      fd <- PQ.socket connection >>= maybe (fail "PostgreSQL socket unavailable") pure
      threadWaitWrite fd
      flush connection

waitResult :: PQ.Connection -> IO ()
waitResult connection = do
  consumed <- PQ.consumeInput connection
  unless consumed (fail "PostgreSQL connection lost")
  busy <- PQ.isBusy connection
  when busy $ do
    fd <- PQ.socket connection >>= maybe (fail "PostgreSQL socket unavailable") pure
    threadWaitRead fd
    waitResult connection
