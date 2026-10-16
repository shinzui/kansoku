{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Public servant API for analytics ingestion.
module Kansoku.Ingest.Api
  ( BeaconAPI,
    BeaconEnvelope (..),
    PlainTextJSON,
    decodeBeaconEnvelope,
    BatchAck (..),
    IngestAck (..),
    IngestRoutes (..),
    IngestEvent (..),
    ingestEvent,
    RejectedEvent (..),
  )
where

import Data.Aeson (Object, Value (Object), withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Decoding (toEitherValue)
import Data.Aeson.Decoding.ByteString.Lazy (lbsToTokens)
import Data.Aeson.Decoding.Tokens (TkRecord (..), Tokens (..))
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Set qualified as Set
import Data.Text qualified as Text
import Kansoku.Api.Response (AcceptedResponses, KansokuResult, ProblemJSON)
import Kansoku.Auth.Api (BeaconContext, IngestAuth)
import Kansoku.Event (AnalyticsEvent)
import Kansoku.Prelude
import Network.HTTP.Media ((//), (/:))
import Servant.API
  ( Accept (..),
    JSON,
    MimeRender (..),
    MimeUnrender (..),
    ReqBody,
    type (:>),
  )
import Servant.API.Generic (type (:-))
import Servant.API.MultiVerb (MultiVerb)
import Servant.API.Verbs qualified as Servant

-- | Ingestion routes keyed by field name. Field order is not load-bearing.
data IngestRoutes mode = IngestRoutes
  { postEvent :: mode :- IngestAuth :> "v1" :> "events" :> ReqBody '[JSON] IngestEvent :> MultiVerb 'Servant.POST '[JSON, ProblemJSON] (AcceptedResponses "Event accepted" IngestAck) (KansokuResult IngestAck),
    postBatch :: mode :- IngestAuth :> "v1" :> "batch" :> ReqBody '[JSON] [IngestEvent] :> MultiVerb 'Servant.POST '[JSON, ProblemJSON] (AcceptedResponses "Batch accepted" BatchAck) (KansokuResult BatchAck),
    postBeacon :: mode :- BeaconAPI '[PlainTextJSON, JSON]
  }
  deriving stock (Generic)

-- | This context supplies request metadata and deferred body authentication;
-- it does not read a header credential.
type BeaconAPI media = BeaconContext :> "v1" :> "beacon" :> ReqBody media BeaconEnvelope :> MultiVerb 'Servant.POST '[JSON, ProblemJSON] (AcceptedResponses "Batch accepted" BatchAck) (KansokuResult BatchAck)

-- Deliberately no Show instance: the envelope contains a credential.
data BeaconEnvelope = BeaconEnvelope
  { writeKey :: !Text,
    batch :: ![IngestEvent]
  }
  deriving stock (Generic, Eq)
  deriving anyclass (ToJSON)

instance FromJSON BeaconEnvelope where
  parseJSON = withObject "BeaconEnvelope" $ \object -> do
    key <- object .: "writeKey"
    unless (not (Text.null key) && Text.length key <= 256 && Text.all (\c -> c > ' ' && c <= '~') key) $
      fail "invalid beacon envelope"
    BeaconEnvelope key <$> object .: "batch"

data PlainTextJSON

instance Accept PlainTextJSON where
  contentTypes _ = ("text" // "plain" /: ("charset", "utf-8")) :| ["text" // "plain"]

instance MimeRender PlainTextJSON BeaconEnvelope where
  mimeRender _ = Aeson.encode

instance MimeUnrender PlainTextJSON BeaconEnvelope where
  mimeUnrender _ = decodeBeaconEnvelope

-- The specialized JSON decoder keeps both media types identical and prevents
-- Servant's parse-error response from including producer input or credentials.
instance {-# OVERLAPPING #-} MimeUnrender JSON BeaconEnvelope where
  mimeUnrender _ = decodeBeaconEnvelope

-- | Reject duplicate root keys before Aeson builds a last-value-wins map.
-- Token keys are already unescaped, including Unicode escape spellings.
decodeBeaconEnvelope :: LBS.ByteString -> Either String BeaconEnvelope
decodeBeaconEnvelope bytes = either (const (Left "invalid beacon envelope")) Right $ do
  let tokens = lbsToTokens bytes
  case tokens of
    TkRecordOpen fields -> unique Set.empty fields
    _ -> Left "object required"
  (value, trailing) <- toEitherValue tokens
  unless (LBS.all (\w -> w `elem` [32, 9, 10, 13]) trailing) (Left "trailing data")
  parseEither parseJSON value
  where
    unique seen (TkPair key value)
      | Set.member key seen = Left "duplicate field"
      | otherwise = do
          (_, next) <- toEitherValue value
          unique (Set.insert key seen) next
    unique _ (TkRecordEnd _) = Right ()
    unique _ (TkRecordErr _) = Left "malformed object"

data IngestAck = IngestAck
  { accepted :: !Int,
    eventId :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | One rejected event in a batch. The zero-based index is the stable
-- machine-usable correlation key; the error text is for people, not parsers.
data RejectedEvent = RejectedEvent
  { index :: !Int,
    eventId :: !(Maybe Text),
    errors :: ![Text]
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A parsed batch is always acknowledged with HTTP 202. Valid events are
-- enqueued and invalid events are reported here so clients never retry them.
data BatchAck = BatchAck
  { accepted :: !Int,
    rejected :: ![RejectedEvent]
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | The parsed event and the exact original event object. Only the object is
-- represented on the wire; normalized queue records remain AnalyticsEvent.
data IngestEvent = IngestEvent
  { parsedEvent :: !AnalyticsEvent,
    originalPayload :: !Object
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON IngestEvent where
  parseJSON = withObject "AnalyticsEvent" $ \object ->
    IngestEvent <$> parseJSON (Object object) <*> pure object

instance ToJSON IngestEvent where
  toJSON = Object . originalPayload

ingestEvent :: AnalyticsEvent -> IngestEvent
ingestEvent event = case toJSON event of
  Object object -> IngestEvent event object
  _ -> error "AnalyticsEvent JSON must be an object"
