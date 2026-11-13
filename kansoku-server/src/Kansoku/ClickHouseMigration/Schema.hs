-- | Compare qualified native metadata. Namespace mapping applies only to parsed
-- relation positions; literals and unrelated identifiers retain their values.
module Kansoku.ClickHouseMigration.Schema (compareSnapshot, normalizeDefinition, policyExpectation) where

import ClickHouseMigrate.Target qualified as T
import Control.Monad (unless)
import Data.Aeson qualified as A
import Data.Char (isAlphaNum, isSpace, toUpper)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Kansoku.Admin.Store (field)
import Kansoku.ClickHouseMigration.SchemaExpectation qualified as Expected

data Token = Bare !Text | Quoted !Text | Literal !Text | Symbol !Char deriving (Eq, Show)

-- Only these supported operational schema values may vary from a fresh release.
policyExpectation :: A.Value -> Either Text (Integer, Maybe Integer)
policyExpectation policy = do
  revision <- decode (field "revision" policy)
  days <- decode (field "days" policy) :: Either Text Integer
  cutoff <- decode (field "cutoff" policy) :: Either Text (Maybe UTCTime)
  unless (revision >= 0 && days >= 0 && (revision == 0 && cutoff == Nothing || revision > 0 && cutoff /= Nothing)) (Left "Incomplete expected retention policy")
  pure (revision, millis <$> cutoff)

compareSnapshot :: Text -> Text -> A.Value -> A.Value -> [A.Value] -> [A.Value] -> Either Text [Text]
compareSnapshot database definer policy engine tables columns = do
  _ <- policyExpectation policy
  expectedTables <- decode (field "tables" Expected.document)
  expectedColumns <- decode (field "columns" Expected.document) :: Either Text [A.Value]
  actualNames <- traverse (textField "name") tables
  expectedNames <- traverse (textField "name") expectedTables
  unless (length actualNames == length (unique actualNames)) (Left "Duplicate or incomplete table metadata")
  let missing = ["missing object: " <> name | name <- expectedNames, name `notElem` actualNames]
      extra = ["extra object: " <> name | name <- actualNames, name `notElem` expectedNames]
      engines = ["application database engine" | engine /= field "databaseEngine" Expected.document]
  differences <- traverse (compareTable tables) expectedTables
  let columnDifferences = ["column metadata: " <> name | name <- expectedNames, filter ((== A.String name) . field "table") columns /= filter ((== A.String name) . field "table") expectedColumns]
  pure (sort (engines <> missing <> extra <> concat differences <> columnDifferences))
  where
    compareTable actual expected = do
      name <- textField "name" expected
      case filter ((== A.String name) . field "name") actual of
        [] -> pure []
        [observed] -> do
          expectedSql <- textField "create_table_query" expected >>= normalizeDefinition "analytics" "default" name (A.object ["days" A..= (0 :: Int), "revision" A..= (0 :: Int), "cutoff" A..= A.Null])
          observedSql <- textField "create_table_query" observed >>= normalizeDefinition database definer name policy
          expectedEngine <- textField "engine_full" expected >>= normalizeDefinition "analytics" "default" name (A.object ["days" A..= (0 :: Int), "revision" A..= (0 :: Int), "cutoff" A..= A.Null])
          observedEngine <- textField "engine_full" observed >>= normalizeDefinition database definer name policy
          let fields = ["engine", "partition_key", "sorting_key", "primary_key", "sampling_key"]
          pure (["definition: " <> name | expectedSql /= observedSql] <> [name <> "/engine_full" | expectedEngine /= observedEngine] <> [name <> "/" <> key | key <- fields, field key expected /= field key observed])
        _ -> Left "Duplicate observed object"
    unique = foldr (\x rest -> if x `elem` rest then rest else x : rest) []

normalizeDefinition :: Text -> Text -> Text -> A.Value -> Text -> Either Text [Token]
normalizeDefinition database definer object policy sql = do
  parsed <- tokenize (Text.unpack sql)
  tokens <- physicalUuid parsed
  (revision, cutoff) <- policyExpectation policy
  stripped <-
    if object == "events_raw" && revision > 0
      then stripRetention cutoff tokens
      else do
        unless (object /= "events_raw" || not (any (keyword "TTL") tokens)) (Left "Unexpected retention TTL without expected applied policy")
        pure tokens
  mapRelations Nothing stripped
  where
    physicalUuid (create : materialized : view : databaseToken : Symbol '.' : name : uuid : Literal value : rest)
      | keyword "CREATE" create && keyword "MATERIALIZED" materialized && keyword "VIEW" view && identifier databaseToken == Just database && identifier name == Just object && keyword "UUID" uuid = do
          either (const (Left "Unsupported physical restore UUID")) (const (pure ())) (T.ledgerId value)
          pure (create : materialized : view : databaseToken : Symbol '.' : name : rest)
    physicalUuid (create : kind : databaseToken : Symbol '.' : name : uuid : Literal value : rest)
      | keyword "CREATE" create && any (`keyword` kind) ["TABLE", "VIEW"] && identifier databaseToken == Just database && identifier name == Just object && keyword "UUID" uuid = do
          either (const (Left "Unsupported physical restore UUID")) (const (pure ())) (T.ledgerId value)
          pure (create : kind : databaseToken : Symbol '.' : name : rest)
    physicalUuid values = Right values
    mapRelations _ [] = Right []
    mapRelations previous (key : value : Symbol '.' : name : rest)
      | relation previous key && identifier value == Just database && identifier name /= Nothing =
          (key :) . (Bare "__kansoku_application__" :) . (Symbol '.' :) . (name :) <$> mapRelations (Just name) rest
    mapRelations _ (key : Symbol '=' : principal : rest)
      | keyword "DEFINER" key = do
          unless (identifier principal == Just definer) (Left "Observed view definer differs from explicit expected principal")
          (key :) . (Symbol '=' :) . (Bare "__kansoku_definer__" :) <$> mapRelations (Just principal) rest
    mapRelations _ (token : rest) = (token :) <$> mapRelations (Just token) rest
    relation previous key = any (`keyword` key) ["TABLE", "VIEW", "TO", "FROM", "JOIN"] && not (keyword "JOIN" key && maybe False (keyword "ARRAY") previous)

-- Match the complete supported DELETE TTL, then remove it for comparison with
-- the fresh immutable definition. Only its JSON scope literal may vary, and its
-- consumed cutoff must equal trusted policy at native DateTime64(3) precision.
stripRetention :: Maybe Integer -> [Token] -> Either Text [Token]
stripRetention expected tokens = do
  let (before, tailTokens) = break (keyword "TTL") tokens
  case tailTokens of
    [] -> Left "Missing applied retention TTL"
    _ : rest -> do
      let (ttl, after) = break (keyword "SETTINGS") rest
      template <- tokenize "toDateTime(occurred_at) WHERE occurred_at < parseDateTime64BestEffort(JSONExtractString('__cutoff__', 'cutoff'), 3, 'UTC')"
      normalized <- replaceScope (implicitDelete ttl)
      unless (normalized == template) (Left "Applied retention TTL differs from supported policy expression")
      pure (before <> after)
  where
    -- Qualified metadata omits DELETE because it is this TTL's default action.
    implicitDelete (function : Symbol '(' : column : Symbol ')' : action : rest)
      | keyword "toDateTime" function && keyword "occurred_at" column && keyword "DELETE" action = function : Symbol '(' : column : Symbol ')' : rest
    implicitDelete values = values
    replaceScope [] = Right []
    replaceScope (function : Symbol '(' : Literal scope : Symbol ',' : Literal "cutoff" : Symbol ')' : rest)
      | keyword "JSONExtractString" function = do
          json <- either (const (Left "Invalid retention TTL scope")) Right (A.eitherDecodeStrict' (Encoding.encodeUtf8 scope))
          cutoff <- decode (field "cutoff" json) :: Either Text UTCTime
          unless (Just (millis cutoff) == expected) (Left "Applied TTL cutoff differs from retained policy")
          (function :) . (Symbol '(' :) . (Literal "__cutoff__" :) . (Symbol ',' :) . (Literal "cutoff" :) . (Symbol ')' :) <$> replaceScope rest
    replaceScope (token : rest) = (token :) <$> replaceScope rest

identifier :: Token -> Maybe Text
identifier (Bare value) = Just value
identifier (Quoted value) = Just value
identifier _ = Nothing

keyword :: Text -> Token -> Bool
keyword expected (Bare actual) = Text.map toUpper expected == Text.map toUpper actual
keyword _ _ = False

tokenize :: String -> Either Text [Token]
tokenize [] = Right []
tokenize (c : rest)
  | isSpace c = tokenize rest
  | c == '\'' = quoted c rest >>= \(value, remaining) -> (Literal (Text.pack value) :) <$> tokenize remaining
  | c == '`' || c == '"' = quoted c rest >>= \(value, remaining) -> (Quoted (Text.pack value) :) <$> tokenize remaining
  | isAlphaNum c || c == '_' || c == '$' = let (word, remaining) = span (\x -> isAlphaNum x || x == '_' || x == '$') (c : rest) in (Bare (Text.pack word) :) <$> tokenize remaining
  | c == ';' = Left "Unexpected statement delimiter in schema metadata"
  | otherwise = (Symbol c :) <$> tokenize rest

quoted :: Char -> String -> Either Text (String, String)
quoted delimiter = go []
  where
    go _ [] = Left "Unterminated quoted schema token"
    go acc ('\\' : x : rest) = do
      decoded <- escape x
      go (decoded : acc) rest
    go acc (x : y : rest) | x == delimiter && y == delimiter = go (x : acc) rest
    go acc (x : rest) | x == delimiter = Right (reverse acc, rest)
    go acc (x : rest) = go (x : acc) rest
    escape 'n' = Right '\n'
    escape 'r' = Right '\r'
    escape 't' = Right '\t'
    escape '0' = Right '\0'
    escape 'b' = Right '\b'
    escape 'f' = Right '\f'
    escape x | x `elem` ['\\', '\'', '"', '`'] = Right x
    escape _ = Left "Unsupported escape in native schema metadata"

millis :: UTCTime -> Integer
millis = floor . (* 1000) . utcTimeToPOSIXSeconds

textField :: Text -> A.Value -> Either Text Text
textField key = decode . field key

decode :: (A.FromJSON a) => A.Value -> Either Text a
decode value = case A.fromJSON value of A.Success result -> Right result; _ -> Left "Incomplete native schema metadata"
