-- | Deterministic funnel reference and the equivalent compiler-owned native fold.
module Kansoku.Metrics.Query.Funnel
  ( FunnelEvent (..),
    SelectedChain (..),
    evaluateFunnel,
    sortedTimelineSQL,
    selectedChainSQL,
  )
where

import Data.Int (Int64)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Ord (comparing)
import Data.Text qualified as Text
import Kansoku.Metrics.Api (FunnelMode (..))
import Kansoku.Prelude

-- | Times are the stored millisecond values, not rounded seconds.
data FunnelEvent = FunnelEvent
  { atMillis :: !Int64,
    eventId :: !Text,
    eventName :: !Text
  }
  deriving stock (Generic, Eq, Ord, Show)

data SelectedChain = SelectedChain
  { level :: !Int,
    eventIds :: ![Text],
    elapsedMillis :: ![Int64]
  }
  deriving stock (Generic, Eq, Show)

-- | Inputs have already passed population/exposure selection. Deduplicate
-- immutable IDs, order by millisecond/id, and consider every possible start.
evaluateFunnel :: FunnelMode -> Int64 -> [Text] -> [Text] -> [FunnelEvent] -> SelectedChain
evaluateFunnel mode window steps excluded inputs = case steps of
  [] -> empty
  firstStep : later -> case candidates firstStep later of
    [] -> empty
    chains -> summarize (List.minimumBy (comparing key) chains)
  where
    empty = SelectedChain 0 [] []
    timeline = List.sortOn (\event -> (atMillis event, eventId event)) (Map.elems (Map.fromListWith min [(eventId event, event) | event <- inputs]))
    candidates firstStep later = [walk event [event] later rest | event : rest <- List.tails timeline, eventName event == firstStep]
    walk _ matched [] _ = matched
    walk _ matched _ [] = matched
    walk start matched wanted@(next : remaining) (event : rest)
      | atMillis event - atMillis start > window = matched
      | eventName event `elem` excluded = matched
      | eventName event == next = walk start (matched <> [event]) remaining rest
      | mode == FunnelStrict = matched
      | otherwise = walk start matched wanted rest
    key [] = (0, 0, 0, [])
    key chain@(first : rest) = (negate (length chain), atMillis (List.foldl' (\_ event -> event) first rest), atMillis first, map eventId chain)
    summarize [] = empty
    summarize chain@(first : _) = SelectedChain (length chain) (map eventId chain) [atMillis event - atMillis first | event <- chain]

-- SQL fragments below are owned by the compiler, never caller SQL. Tuple
-- elements 1/2/3 are milliseconds, immutable event ID and event name; extra
-- attribution elements remain attached while selected indices are evaluated.
sortedTimelineSQL :: Text -> Text
sortedTimelineSQL raw = "arraySort(event->tuple(event.1,event.2),arrayDistinct(" <> raw <> "))"

selectedChainSQL :: Text -> Text -> Text -> Text -> Text -> Text
selectedChainSQL timeline steps excluded window strict =
  "arrayElement(arraySort(indices->tuple(-toInt64(length(indices)),"
    <> timeline
    <> "[arrayElement(indices,-1)].1,"
    <> timeline
    <> "[indices[1]].1,arrayMap(i->"
    <> timeline
    <> "[i].2,indices)),"
    <> "arrayMap(s->arrayFold((acc,j)->if(acc.3=0 OR acc.2>length("
    <> steps
    <> "),acc,"
    <> "if("
    <> timeline
    <> "[j].1-"
    <> timeline
    <> "[s].1>"
    <> window
    <> " OR has("
    <> excluded
    <> ","
    <> timeline
    <> "[j].3),tuple(acc.1,acc.2,toUInt8(0)),"
    <> "if("
    <> timeline
    <> "[j].3="
    <> steps
    <> "[acc.2],tuple(arrayPushBack(acc.1,j),acc.2+1,toUInt8(1)),"
    <> "if("
    <> strict
    <> ",tuple(acc.1,acc.2,toUInt8(0)),acc)))),"
    <> "arraySlice(arrayEnumerate("
    <> timeline
    <> "),s+1),tuple([toUInt64(s)],toUInt64(2),toUInt8(1))).1,"
    <> "arrayFilter(s->"
    <> timeline
    <> "[s].3="
    <> steps
    <> "[1],arrayEnumerate("
    <> timeline
    <> ")))),1)"
