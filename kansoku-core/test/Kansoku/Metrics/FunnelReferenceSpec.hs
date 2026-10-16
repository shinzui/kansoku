module Kansoku.Metrics.FunnelReferenceSpec (spec) where

import ClickHaskell (ChString, ClickHaskell, Column, Connection, Select, command, select, unsafeMkSelect)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Word (Word64)
import Kansoku.ClickHouseTestSupport
import Kansoku.Metrics.Api (FunnelMode (..))
import Kansoku.Metrics.Query.Funnel qualified as Funnel
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = do
  describe "Kansoku.Funnel reference" $ do
    it "lets sequential chains skip automatic events while strict requires adjacency" $ do
      let rows = [node 0 "a" "a", node 500 "page" "page_view", node 1000 "b" "b"]
      Funnel.level (evaluate FunnelSequential ["a", "b"] [] rows) `shouldBe` 2
      Funnel.level (evaluate FunnelStrict ["a", "b"] [] rows) `shouldBe` 1
    it "never lets one physical event satisfy two repeated steps, including duplicate delivery" $ do
      let a = node 0 "a" "a"
      forM_ [FunnelSequential, FunnelStrict] $ \mode -> do
        Funnel.level (evaluate mode ["a", "a"] [] [a]) `shouldBe` 1
        Funnel.level (evaluate mode ["a", "a"] [] [a, a]) `shouldBe` 1
        Funnel.level (evaluate mode ["a", "a"] [] [a, node 0 "z" "a"]) `shouldBe` 2
    it "orders equal milliseconds by event ID before matching" $ do
      let rows = [node 0 "z" "a", node 0 "a" "b"]
      forM_ [FunnelSequential, FunnelStrict] $ \mode -> Funnel.level (evaluate mode ["a", "b"] [] rows) `shouldBe` 1
    it "uses the inclusive millisecond window without rounding to seconds" $ do
      Funnel.level (evaluate FunnelSequential ["a", "b"] [] [node 0 "a" "a", node 1000 "b" "b"]) `shouldBe` 2
      Funnel.level (evaluate FunnelSequential ["a", "b"] [] [node 0 "a" "a", node 1001 "b" "b"]) `shouldBe` 1
    it "considers a new start after a failed strict attempt without implicit deduplication" $ do
      let result = evaluate FunnelStrict ["a", "b"] [] [node 0 "one" "a", node 500 "two" "a", node 1000 "three" "b"]
      Funnel.eventIds result `shouldBe` ["two", "three"]
      Funnel.elapsedMillis result `shouldBe` [0, 500]
    it "invalidates an intervening exclusion but permits a later chain" $ do
      let result = Funnel.evaluateFunnel FunnelSequential 2000 ["a", "b"] ["x"] [node 0 "one" "a", node 500 "x" "x", node 1000 "two" "a", node 1500 "three" "b"]
      Funnel.eventIds result `shouldBe` ["two", "three"]
      Funnel.elapsedMillis result `shouldBe` [0, 500]
    it "chooses maximum reach before completion time" $ do
      let result = evaluate FunnelSequential ["a", "b", "c"] [] [node 0 "early" "a", node 500 "late" "a", node 900 "b" "b", node 1100 "c" "c"]
      Funnel.eventIds result `shouldBe` ["late", "b", "c"]
      Funnel.elapsedMillis result `shouldBe` [0, 400, 600]
    it "breaks equal reach by earliest completion and then earliest start" $ do
      let rows = [node 0 "one" "a", node 500 "two" "a", node 1000 "three" "b", node 1500 "four" "b"]
          result = Funnel.evaluateFunnel FunnelSequential 2000 ["a", "b"] [] rows
      Funnel.eventIds result `shouldBe` ["one", "three"]
      Funnel.elapsedMillis result `shouldBe` [0, 1000]
    it "breaks remaining ties by event IDs and ignores input/replay order" $ do
      let rows = [node 0 "z" "a", node 0 "a" "a", node 500 "b" "b"]
          selected = evaluate FunnelSequential ["a", "b"] [] rows
      Funnel.eventIds selected `shouldBe` ["a", "b"]
      evaluate FunnelSequential ["a", "b"] [] (reverse rows <> rows) `shouldBe` selected
    it "returns zero reach without an eligible first step" $ do
      evaluate FunnelSequential ["a", "b"] [] [] `shouldBe` Funnel.SelectedChain 0 [] []
      evaluate FunnelSequential ["a", "b"] [] [node 0 "b" "b"] `shouldBe` Funnel.SelectedChain 0 [] []

  describe "Kansoku.Funnel native parity" $ do
    it "matches the reference on 1000 seeded timelines in both modes with full chain IDs and millisecond durations" $ withClickHouse $ \connection -> do
      command connection "SET max_execution_time=30,max_memory_usage=536870912"
      command connection "CREATE TEMPORARY TABLE native_funnel_cases(case_id UInt64,raw Array(Tuple(Int64,String,String)),steps Array(String),excluded Array(String),window_ms Int64,strict UInt8) ENGINE=Memory"
      let cases = concat [[sample (2 * seed) seed FunnelSequential, sample (2 * seed + 1) seed FunnelStrict] | seed <- [1 .. 1000]]
      forM_ (chunks 100 cases) $ \batch -> command connection (fromString (Text.unpack ("INSERT INTO native_funnel_cases VALUES " <> Text.intercalate "," (map caseValues batch))))
      let sql = "SELECT toJSONString(tuple(case_id,arrayMap(i->timeline[i].2,selected),arrayMap(i->timeline[i].1-timeline[selected[1]].1,selected))) AS value FROM (SELECT *," <> Funnel.selectedChainSQL "timeline" "steps" "excluded" "window_ms" "strict" <> " AS selected FROM (SELECT *," <> Funnel.sortedTimelineSQL "raw" <> " AS timeline FROM native_funnel_cases)) ORDER BY case_id SETTINGS short_circuit_function_evaluation='force_enable'"
      actual <- values connection sql
      let expected = [Aeson.toJSON (ident, Funnel.eventIds result, Funnel.elapsedMillis result) | Case ident mode window steps excluded rows <- cases, let result = Funnel.evaluateFunnel mode window steps excluded rows]
      length actual `shouldBe` 2000
      actual `shouldBe` expected
    it "proves default windowFunnel is not equivalent on repeated names or ID-ordered timestamp ties" $ withClickHouse $ \connection -> do
      first <- values connection "SELECT toJSONString(windowFunnel(1000)(toUInt64(0),name='a',name='a')) AS value FROM (SELECT 'a' AS name)"
      second <- values connection "SELECT toJSONString(windowFunnel(1000)(toUInt64(stamp),name='a',name='b')) AS value FROM (SELECT tupleElement(event,1) AS stamp,tupleElement(event,3) AS name FROM (SELECT arrayJoin([(0,'a','b'),(0,'z','a')]) AS event))"
      (first <> second) `shouldNotBe` [Aeson.Number 1, Aeson.Number 1]

node :: Int64 -> Text -> Text -> Funnel.FunnelEvent
node = Funnel.FunnelEvent

evaluate :: FunnelMode -> [Text] -> [Text] -> [Funnel.FunnelEvent] -> Funnel.SelectedChain
evaluate mode = Funnel.evaluateFunnel mode 1000

data Case = Case Int FunnelMode Int64 [Text] [Text] [Funnel.FunnelEvent]

sample :: Int -> Int -> FunnelMode -> Case
sample ident seed mode =
  let randoms = map fromIntegral (take 100 (drop 1 (iterate (\value -> value * 6364136223846793005 + 1442695040888963407) (fromIntegral seed :: Word64)))) :: [Integer]
      count = fromInteger (fromMaybe 0 (listToMaybe randoms) `mod` 18)
      countSteps = 1 + fromInteger (randoms !! 1 `mod` 4)
      names = ["a", "b", "c", "page_view", "x"]
      steps = [names !! fromInteger (number `mod` 3) | number <- take countSteps (drop 2 randoms)]
      stamps = scanl (+) 0 [fromInteger (number `mod` 701) | number <- take count (drop 12 randoms)]
      rows = [node stamp (Text.pack (show seed <> "-" <> pad position)) (names !! fromInteger (number `mod` 5)) | (position, (stamp, number)) <- zip [0 ..] (zip stamps (take count (drop 40 randoms)))]
      replay = if seed `mod` 4 == 0 then take 2 rows <> rows else rows
      ordered = if odd seed then reverse replay else replay
   in Case ident mode (1000 * fromIntegral (1 + seed `mod` 5)) steps ["x" | seed `mod` 3 == 0] ordered
  where
    pad n = let value = show (n :: Int) in replicate (5 - length value) '0' <> value

caseValues :: Case -> Text
caseValues (Case ident mode window steps excluded rows) = "(" <> number ident <> ",[" <> Text.intercalate "," ["(" <> number (Funnel.atMillis event) <> "," <> quoted (Funnel.eventId event) <> "," <> quoted (Funnel.eventName event) <> ")" | event <- rows] <> "]," <> strings steps <> "," <> strings excluded <> "," <> number window <> "," <> (if mode == FunnelStrict then "1" else "0") <> ")"
  where
    number :: (Show a) => a -> Text
    number = Text.pack . show
    quoted value = "'" <> value <> "'" -- generated ASCII fixture alphabet only
    strings items = "[" <> Text.intercalate "," (map quoted items) <> "]"

chunks :: Int -> [a] -> [[a]]
chunks _ [] = []
chunks size items = let (first, rest) = splitAt size items in first : chunks size rest

newtype JsonRow = JsonRow {value :: BS.ByteString}
  deriving stock (Generic)
  deriving anyclass (ClickHaskell '[Column "value" ChString])

values :: Connection -> Text -> IO [Aeson.Value]
values connection sql = do
  rows <- concat . reverse <$> select (unsafeMkSelect (const (Text.encodeUtf8Builder sql)) :: Select '[Column "value" ChString] JsonRow) connection pure
  traverse (\(JsonRow bytes) -> either fail pure (Aeson.eitherDecodeStrict' bytes)) rows
