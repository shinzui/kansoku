-- | Small parameterized native SQL boundary shared by consistency and administration.
module Kansoku.ClickHouse.Native (chCommand, chJSON, scopeText, ConsistencyError (..), failConsistency) where

import ClickHaskell (ChString, ClickHaskell, ClientError (..), Column, Connection, Select, ToChType (toChType), addParameter, command, passParameters, select, unsafeMkSelect)
import ClickHaskell.Protocol (ExceptionPacket (..))
import Control.Exception (Exception, fromException, throwIO)
import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kansoku.Exception (catchSynchronous)
import Kansoku.Prelude
import System.Timeout (timeout)

newtype JsonRow = JsonRow {value :: BS.ByteString}
  deriving stock (Generic)
  deriving anyclass (ClickHaskell '[Column "value" ChString])

scopeText :: A.Value -> BS.ByteString
scopeText = LBS.toStrict . A.encode

chCommand :: Connection -> A.Value -> Text -> IO ()
chCommand connection scope sql =
  nativeFailure (Text.takeWhile (/= ' ') sql) $
    boundedNative $
      command connection $
        passParameters (addParameter "admin_scope" (toChType (scopeText scope) :: ChString)) (fromString (Text.unpack sql))

chJSON :: Connection -> A.Value -> Text -> IO [A.Value]
chJSON connection scope sql = nativeFailure "SELECT" $ boundedNative $ do
  let statement =
        passParameters
          (addParameter "admin_scope" (toChType (scopeText scope) :: ChString))
          (unsafeMkSelect (const (Text.encodeUtf8Builder sql)) :: Select '[Column "value" ChString] JsonRow)
  rows <- concat . reverse <$> select statement connection pure
  traverse (\(JsonRow bytes) -> either (const (fail "invalid maintenance native result")) pure (A.eitherDecodeStrict' bytes)) rows

boundedNative :: IO a -> IO a
boundedNative action = timeout 60_000_000 action >>= maybe (failConsistency "native statement deadline expired; maintenance fence retained") pure

-- Only this deliberately redacted diagnostic type is rendered by the admin CLI.
newtype ConsistencyError = ConsistencyError Text deriving stock (Show)

instance Exception ConsistencyError

failConsistency :: String -> IO a
failConsistency = throwIO . ConsistencyError . Text.pack

nativeFailure :: Text -> IO a -> IO a
nativeFailure operation action = catchSynchronous action $ \exception ->
  case fromException exception of
    Just (DatabaseException packet) -> failConsistency (Text.unpack operation <> " rejected by native server (code " <> show (code packet) <> "); details redacted; fence retained")
    Just (_ :: ClientError) -> failConsistency (Text.unpack operation <> " native protocol or connection failure; fence retained")
    Nothing -> throwIO exception
