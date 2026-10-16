-- | The bounded JSON grammar shared by metric producers and the server.
module Kansoku.Metrics.Filter
  ( FilterOp (..),
    MetricFilter,
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
import Data.Foldable (toList)
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

data MetricFilter = MetricFilter
  { dimension :: !Text,
    op :: !FilterOp,
    value :: !(Maybe Aeson.Value),
    decodedBytes :: !Int
  }
  deriving stock (Generic, Show)

instance Eq MetricFilter where
  left == right = dimension left == dimension right && op left == op right && value left == value right

instance ToJSON MetricFilter where
  toJSON MetricFilter {dimension, op, value} =
    Aeson.object (["dimension" Aeson..= dimension, "op" Aeson..= op] <> maybe [] (\operand -> ["value" Aeson..= operand]) value)

instance FromJSON MetricFilter where
  parseJSON = Aeson.withObject "metric filter" $ \object -> do
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
  | ["cohort", operator, ident] <- Text.splitOn ":" raw, Just op <- lookup operator [("eq", FilterEq), ("neq", FilterNeq)] = mkMetricFilter "cohort" op (Just (Aeson.String ident))
  | utf8Size raw > maxFilterBytes = Left "decoded filters are limited to 16384 UTF-8 bytes"
  | otherwise = do
      parsed <- first Text.pack (Aeson.eitherDecodeStrict' (Text.encodeUtf8 raw))
      pure parsed {decodedBytes = utf8Size raw}

-- The HTTP boundary also checks the original decoded byte lengths, including
-- whitespace. This check covers direct compiler calls and typed producers.
validateMetricFilters :: [MetricFilter] -> Either Text [MetricFilter]
validateMetricFilters filters
  | length filters > maxFilters = Left "at most eight filters are supported"
  | sum (map decodedBytes filters) > maxFilterBytes = Left "decoded filters are limited to 16384 UTF-8 bytes"
  | otherwise = traverse (\input -> input <$ mkMetricFilter (dimension input) (op input) (value input)) filters

mkMetricFilter :: Text -> FilterOp -> Maybe Aeson.Value -> Either Text MetricFilter
mkMetricFilter name operator operand =
  case Aeson.fromJSON (Aeson.object (["dimension" Aeson..= name, "op" Aeson..= operator] <> maybe [] (\input -> ["value" Aeson..= input]) operand)) of
    Aeson.Error message -> Left (Text.pack message)
    Aeson.Success result -> Right result

utf8Size :: Text -> Int
utf8Size = BS.length . Text.encodeUtf8
