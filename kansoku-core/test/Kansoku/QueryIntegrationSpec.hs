module Kansoku.QueryIntegrationSpec (spec) where

import ClickHaskell (ClickHaskell, Column, Select, UInt8, select, unsafeMkSelect)
import Control.Concurrent.Async (mapConcurrently)
import Data.Time.Clock (NominalDiffTime, diffUTCTime)
import Data.Word (Word8)
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Query integration" $ do
  it "runs concurrent queries in parallel across the pool" $
    withClickHouse $ \_conn -> do
      cfg <- clickHouseConfigFromConfig <$> requireConfig
      pooled <- timedSleeps 4 cfg
      pooled `shouldSatisfy` (< 2.5)

  it "serializes when the pool has a single connection (control)" $
    withClickHouse $ \_conn -> do
      cfg <- clickHouseConfigFromConfig <$> requireConfig
      serialized <- timedSleeps 1 cfg
      serialized `shouldSatisfy` (>= 4)

type SleepColumns = '[Column "s" UInt8]

newtype SleepRow = SleepRow {s :: Word8}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ClickHaskell SleepColumns)

sleep1Select :: Select SleepColumns SleepRow
sleep1Select = unsafeMkSelect (const "SELECT toUInt8(sleep(1)) AS s")

timedSleeps :: Int -> ClickHouseConfig -> IO NominalDiffTime
timedSleeps poolSize cfg = do
  queryPool <- newQueryPool cfg poolSize
  started <- getCurrentTime
  _ <- mapConcurrently (\_ -> withQueryConnection queryPool (\conn -> select sleep1Select conn pure)) [1 :: Int .. 4]
  finished <- getCurrentTime
  pure (diffUTCTime finished started)
