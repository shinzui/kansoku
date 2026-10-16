-- | Deterministic funnel reference and the equivalent compiler-owned native fold.
module Kansoku.Metrics.Query.Funnel
  ( FunnelEvent (..),
    SelectedChain (..),
    evaluateFunnel,
    evaluateEntries,
    sortedTimelineSQL,
    selectedChainSQL,
    entryChainsSQL,
  )
where

import Data.Int (Int64)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Ord (comparing)
import Kansoku.Metrics.Api (FunnelCounting (..), FunnelMode (..))
import Kansoku.Prelude hiding (strict)

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
evaluateFunnel FunnelAnyOrder window steps excluded inputs =
  fromMaybe (SelectedChain 0 [] []) (listToMaybe (evaluateEntries FunnelAnyOrder FunnelUniques window steps excluded inputs))
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

-- | Nonoverlapping attempts. An expired/aborted attempt keeps its reached prefix;
-- the event that ends it can start the next attempt. Completion consumes its event.
-- Any-order uniques opens exactly one window at the earliest matching event.
evaluateEntries :: FunnelMode -> FunnelCounting -> Int64 -> [Text] -> [Text] -> [FunnelEvent] -> [SelectedChain]
evaluateEntries _ _ _ [] _ _ = []
evaluateEntries mode counting window steps excluded inputs = map summarize (go [] [] [] timeline)
  where
    timeline = List.sortOn (\event -> (atMillis event, eventId event)) (Map.elems (Map.fromListWith min [(eventId event, event) | event <- inputs]))
    next positions event = listToMaybe [i | (i, name) <- zip [1 ..] steps, name == eventName event, i `notElem` positions, mode == FunnelAnyOrder || i == length positions + 1]
    start done event rest = case next [] event of
      Nothing -> go done [] [] rest
      Just position -> advance done [] [] position event rest
    advance done matched positions position event rest =
      let chain = matched <> [event]
       in if length chain == length steps then finish done chain rest else go done chain (positions <> [position]) rest
    finish done chain rest
      | counting == FunnelUniques = done <> [chain]
      | otherwise = go (done <> [chain]) [] [] rest
    go done [] _ [] = done
    go done matched _ [] = done <> [matched]
    go done [] _ (event : rest) = start done event rest
    go done matched@(first : _) positions (event : rest)
      | atMillis event - atMillis first > window || eventName event `elem` excluded =
          if counting == FunnelUniques then done <> [matched] else start (done <> [matched]) event rest
      | Just position <- next positions event = advance done matched positions position event rest
      | mode == FunnelStrict =
          if counting == FunnelUniques then done <> [matched] else start (done <> [matched]) event rest
      | otherwise = go done matched positions rest
    summarize [] = SelectedChain 0 [] []
    summarize chain@(first : _) = SelectedChain (length chain) (map eventId chain) [atMillis event - atMillis first | event <- chain]

-- | Return arrays of timeline indices, retaining event-order reach for any-order.
-- State is (finished attempts, current indices, matched step positions). Distinct
-- positions allow repeated step names without reusing a physical event.
entryChainsSQL :: Text -> Text -> Text -> Text -> Bool -> Bool -> Bool -> Text
entryChainsSQL timeline steps excluded window strict anyOrder totals =
  "arrayMap(state->arrayConcat(state.1,if(empty(state.2),"
    <> emptyChains
    <> ",[state.2])),["
    <> "arrayFold((acc,j)->"
    <> transition
    <> ",arrayEnumerate("
    <> timeline
    <> "),tuple("
    <> emptyChains
    <> ","
    <> emptyIndices
    <> ","
    <> emptyIndices
    <> "))])[1]"
  where
    emptyIndices = "CAST([],'Array(UInt64)')"
    emptyChains = "CAST([],'Array(Array(UInt64))')"
    name = timeline <> "[j].3"
    position = if anyOrder then "arrayFirstIndex(p->" <> steps <> "[p]=" <> name <> " AND NOT has(acc.3,p),arrayEnumerate(" <> steps <> "))" else "if(" <> name <> "=" <> steps <> "[length(acc.2)+1],length(acc.2)+1,toUInt64(0))"
    firstPosition = if anyOrder then "indexOf(" <> steps <> "," <> name <> ")" else "if(" <> name <> "=" <> steps <> "[1],toUInt64(1),toUInt64(0))"
    finished = "if(empty(acc.2),acc.1,arrayPushBack(acc.1,acc.2))"
    seed done = "if(" <> firstPosition <> "=0,tuple(" <> done <> "," <> emptyIndices <> "," <> emptyIndices <> ")," <> append done emptyIndices emptyIndices firstPosition <> ")"
    append done current positions pos =
      "if(length(" <> current <> ")+1=length(" <> steps <> "),tuple(arrayPushBack(" <> done <> ",arrayPushBack(" <> current <> ",j))," <> emptyIndices <> "," <> emptyIndices <> "),tuple(" <> done <> ",arrayPushBack(" <> current <> ",j),arrayPushBack(" <> positions <> ",toUInt64(" <> pos <> "))))"
    abort = if totals then seed finished else "tuple(" <> finished <> "," <> emptyIndices <> "," <> emptyIndices <> ")"
    expired = timeline <> "[j].1-" <> timeline <> "[acc.2[1]].1>" <> window <> " OR has(" <> excluded <> "," <> name <> ")"
    active = "if(" <> expired <> "," <> abort <> ",if(" <> position <> ">0," <> append "acc.1" "acc.2" "acc.3" position <> "," <> (if strict then abort else "acc") <> "))"
    transition = "if(" <> (if totals then "0" else "notEmpty(acc.1)") <> ",acc,if(empty(acc.2)," <> seed "acc.1" <> "," <> active <> "))"

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
