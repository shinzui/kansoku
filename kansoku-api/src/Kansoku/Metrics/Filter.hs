-- | The bounded JSON grammar shared by metric producers and the server.
module Kansoku.Metrics.Filter
  ( FilterOp (..),
    MetricFilter,
    filterTerms,
    mapFilterTerms,
    dimension,
    op,
    value,
    mkMetricFilter,
    filterOpText,
    parseMetricFilter,
    validateMetricFilters,
    maxFilters,
    maxFilterBytes,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList, traverse_)
import Data.List (sort)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kansoku.Prelude hiding (op)
import Web.HttpApiData (FromHttpApiData (..), ToHttpApiData (..))

data FilterOp = FilterEq | FilterNeq | FilterIn | FilterContains | FilterGt | FilterLt | FilterSet | FilterUnset
  deriving stock (Generic, Eq, Show)

filterOpText :: FilterOp -> Text
filterOpText = \case
  FilterEq -> "eq"
  FilterNeq -> "neq"
  FilterIn -> "in"
  FilterContains -> "contains"
  FilterGt -> "gt"
  FilterLt -> "lt"
  FilterSet -> "set"
  FilterUnset -> "unset"

instance ToJSON FilterOp where
  toJSON = Aeson.String . filterOpText

instance FromJSON FilterOp where
  parseJSON = Aeson.withText "filter operator" $ \raw ->
    maybe (fail "unsupported filter operator") pure $
      lookup raw [(filterOpText operator, operator) | operator <- [FilterEq, FilterNeq, FilterIn, FilterContains, FilterGt, FilterLt, FilterSet, FilterUnset]]

data MetricFilter
  = MetricFilter
      { dimension :: !Text,
        op :: !FilterOp,
        value :: !(Maybe Aeson.Value),
        decodedBytes :: !Int
      }
  | MetricFilterGroup {alternatives :: ![MetricFilter], decodedBytes :: !Int}
  deriving stock (Generic, Show)

filterTerms :: MetricFilter -> [MetricFilter]
filterTerms (MetricFilterGroup terms _) = terms
filterTerms term = [term]

mapFilterTerms :: (MetricFilter -> MetricFilter) -> MetricFilter -> MetricFilter
mapFilterTerms f (MetricFilterGroup terms bytes) = MetricFilterGroup (map f terms) bytes
mapFilterTerms f term = f term

instance Eq MetricFilter where
  left == right = toJSON left == toJSON right

instance ToJSON MetricFilter where
  toJSON (MetricFilterGroup terms _) = Aeson.object ["or" Aeson..= terms]
  toJSON MetricFilter {dimension, op, value} =
    Aeson.object (["dimension" Aeson..= dimension, "op" Aeson..= op] <> maybe [] (\operand -> ["value" Aeson..= operand]) value)

instance FromJSON MetricFilter where
  parseJSON input@(Aeson.Object object) | KeyMap.member "or" object = do
    unless (KeyMap.keys object == ["or"]) (fail "OR groups require exactly or")
    terms <- object Aeson..: "or"
    unless (not (null terms) && length terms <= 8 && all isAtomic terms) (fail "OR groups require 1..8 non-nested terms")
    pure (MetricFilterGroup terms (fromIntegral (LBS.length (Aeson.encode input))))
  parseJSON input = parseTerm input

isAtomic :: MetricFilter -> Bool
isAtomic MetricFilter {} = True
isAtomic _ = False

parseTerm :: Aeson.Value -> Parser MetricFilter
parseTerm = Aeson.withObject "metric filter" $ \object -> do
  dimension <- object Aeson..: "dimension"
  op <- object Aeson..: "op"
  let noOperand = op `elem` [FilterSet, FilterUnset]
      expected = if noOperand then ["dimension", "op"] else ["dimension", "op", "value"]
  unless (sort (KeyMap.keys object) == sort expected) (fail "filter requires exactly dimension/op and value, except set/unset")
  unless (not (Text.null dimension) && utf8Size dimension <= 1024) (fail "filter dimension must be a nonempty string of at most 1024 UTF-8 bytes")
  optionalOperand <- if noOperand then pure Nothing else Just <$> object Aeson..: "value"
  case (op, optionalOperand) of
    (_, Nothing) -> pure ()
    (FilterIn, Just (Aeson.Array values)) -> do
      let operands = toList values
      unless (not (null operands) && length operands <= 100) (fail "in requires 1..100 scalar values")
      types <- traverse scalarType operands
      case types of
        kind : rest | all (== kind) rest -> pure ()
        _ -> fail "in values must have the same scalar type"
    (FilterIn, _) -> fail "in requires an array"
    (FilterContains, Just operand@(Aeson.String _)) -> void (scalarType operand)
    (FilterContains, _) -> fail "contains requires a string"
    (operator, Just operand) | operator `elem` [FilterGt, FilterLt] -> do
      kind <- scalarType operand
      unless (kind == "number") (fail "gt/lt require a finite number")
    (_, Just operand) -> void (scalarType operand)
  let result = MetricFilter {dimension, op, value = optionalOperand, decodedBytes = 0}
  pure result {decodedBytes = utf8Size (toUrlPiece result)}

scalarType :: Aeson.Value -> Parser Text
scalarType = \case
  Aeson.String text -> do
    unless (utf8Size text <= 1024) (fail "filter strings are limited to 1024 UTF-8 bytes")
    pure "string"
  operand@(Aeson.Number _) -> case Aeson.fromJSON operand :: Aeson.Result Double of
    Aeson.Success number | not (isInfinite number || isNaN number) -> pure "number"
    _ -> fail "filter numbers must be finite Float64 values"
  Aeson.Bool _ -> pure "boolean"
  _ -> fail "filter operands must be non-null strings, finite numbers or booleans"

instance FromHttpApiData MetricFilter where
  parseUrlPiece = parseMetricFilter

instance ToHttpApiData MetricFilter where
  toUrlPiece = Text.decodeUtf8 . LBS.toStrict . Aeson.encode

maxFilters, maxFilterBytes :: Int
maxFilters = 8
maxFilterBytes = 16384

parseMetricFilter :: Text -> Either Text MetricFilter
parseMetricFilter raw
  | utf8Size raw > maxFilterBytes = Left "decoded filters are limited to 16384 UTF-8 bytes"
  | Text.isPrefixOf "{" (Text.stripStart raw) = do
      parsed <- first Text.pack (Aeson.eitherDecodeStrict' (Text.encodeUtf8 raw))
      pure parsed {decodedBytes = utf8Size raw}
  | otherwise = do
      let pieces = Text.splitOn "|" raw
      unless (length pieces <= 8) (Left "OR groups support at most eight terms")
      terms <- traverse shorthand pieces
      pure $ case terms of
        [term] -> term {decodedBytes = utf8Size raw}
        _ -> MetricFilterGroup terms (utf8Size raw)
  where
    shorthand text = do
      let parts = Text.splitOn ":" text
          (name, rest) = case parts of
            prefix : key : tail | prefix `elem` ["prop", "user"] -> (prefix <> ":" <> key, tail)
            key : tail -> (key, tail)
            [] -> ("", [])
      case rest of
        [operator] | Just op <- lookup operator [("set", FilterSet), ("unset", FilterUnset)] -> mkMetricFilter name op Nothing
        operator : operands
          | not (null operands),
            Just op <- lookup operator [(filterOpText x, x) | x <- [FilterEq, FilterNeq, FilterIn, FilterContains, FilterGt, FilterLt]] ->
              let operand = Text.intercalate ":" operands
                  scalar = case Aeson.eitherDecodeStrict' (Text.encodeUtf8 operand) of
                    Right v@(Aeson.String _) -> v
                    Right v@(Aeson.Number _) -> v
                    Right v@(Aeson.Bool _) -> v
                    _ -> Aeson.String operand
                  parsed = if op == FilterIn then either (const (Aeson.String operand)) id (Aeson.eitherDecodeStrict' (Text.encodeUtf8 operand)) else scalar
               in mkMetricFilter name op (Just parsed)
        _ -> Left "expected dimension:op:value (literal | requires the JSON form)"

-- The HTTP boundary also checks the original decoded byte lengths, including
-- whitespace. This check covers direct compiler calls and typed producers.
validateMetricFilters :: [MetricFilter] -> Either Text [MetricFilter]
validateMetricFilters filters
  | length filters > maxFilters = Left "at most eight filters are supported"
  | sum (map decodedBytes filters) > maxFilterBytes = Left "decoded filters are limited to 16384 UTF-8 bytes"
  | otherwise = traverse validate filters
  where
    validate input = do
      let terms = filterTerms input
      unless (not (null terms) && length terms <= 8) (Left "OR groups require 1..8 terms")
      traverse_ (\term -> void (mkMetricFilter (dimension term) (op term) (value term))) terms
      pure input

mkMetricFilter :: Text -> FilterOp -> Maybe Aeson.Value -> Either Text MetricFilter
mkMetricFilter name operator operand =
  case Aeson.fromJSON (Aeson.object (["dimension" Aeson..= name, "op" Aeson..= operator] <> maybe [] (\input -> ["value" Aeson..= input]) operand)) of
    Aeson.Error message -> Left (Text.pack message)
    Aeson.Success result -> Right result

utf8Size :: Text -> Int
utf8Size = BS.length . Text.encodeUtf8
