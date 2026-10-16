{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Haskell server SDK for emitting Kansoku analytics events.
module Kansoku.Client
  ( Client,
    ClientConfig (..),
    ClientError (..),
    EventIds (..),
    alias,
    close,
    defaultClientConfig,
    droppedCount,
    emptyIds,
    fetchSchemaCatalog,
    flush,
    group,
    identify,
    identifyWithVersion,
    identifyOnce,
    identifyOnceWithVersion,
    kansokuBeaconContext,
    kansokuCredential,
    newClient,
    track,
    trackEvent,
    trackEventWithVersion,
    withClient,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel)
import Control.Concurrent.STM (STM, TBQueue, TVar, atomically, isFullTBQueue, modifyTVar', newTBQueueIO, newTVarIO, readTVarIO, tryReadTBQueue, writeTBQueue)
import Control.Exception (bracket)
import Data.Aeson (Object)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair)
import Data.Bifunctor (first)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Kansoku.Api (SchemaAPI)
import Kansoku.Api.Response (KansokuResult (..), ProblemDetails)
import Kansoku.Auth.Api (BeaconContext, IngestAuth)
import Kansoku.Event (AccountId (..), AnalyticsEvent (..), AnonymousId (..), EventId (..), EventName (..), EventSource (..), OrganizationId (..), SessionId (..), UserId (..), baseEvent)
import Kansoku.Event.Contract (SchemaCatalog)
import Kansoku.Ingest.Api (BatchAck, IngestRoutes)
import Kansoku.Ingest.Api qualified as Ingest
import Kansoku.Prelude
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS qualified as HTTP.TLS
import Network.HTTP.Types.Status (statusCode)
import Servant.API (NamedRoutes)
import Servant.API.Experimental.Auth (AuthProtect)
import Servant.Client (BaseUrl, ClientEnv, ClientM, mkClientEnv, parseBaseUrl, runClientM)
import Servant.Client qualified as ServantClient
import Servant.Client.Core.Auth (AuthClientData, AuthenticatedRequest, mkAuthenticatedRequest)
import Servant.Client.Core.Request qualified as ClientRequest
import Servant.Client.Core.Response qualified as ClientResponse
import Servant.Client.Generic (AsClientT)

data ClientConfig = ClientConfig
  { baseUrl :: !Text,
    credential :: !Text,
    sourceService :: !(Maybe Text),
    manager :: !(Maybe HTTP.Manager),
    batchMaxSize :: !Int,
    batchMaxIntervalMicros :: !Int,
    bufferCapacity :: !Int,
    maxRetries :: !Int,
    retryBaseDelayMicros :: !Int
  }
  deriving stock (Generic)

defaultClientConfig :: Text -> Text -> ClientConfig
defaultClientConfig baseUrl credential =
  ClientConfig
    { baseUrl,
      credential,
      sourceService = Nothing,
      manager = Nothing,
      batchMaxSize = 100,
      batchMaxIntervalMicros = 5000000,
      bufferCapacity = 10000,
      maxRetries = 5,
      retryBaseDelayMicros = 100000
    }

data EventIds = EventIds
  { userId :: !(Maybe Text),
    anonymousId :: !(Maybe Text),
    identifiers :: !(Maybe (Map Text Text)),
    organizationId :: !(Maybe Text),
    accountId :: !(Maybe Text),
    sessionId :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

emptyIds :: EventIds
emptyIds =
  EventIds
    { userId = Nothing,
      anonymousId = Nothing,
      identifiers = Nothing,
      organizationId = Nothing,
      accountId = Nothing,
      sessionId = Nothing
    }

data Client = Client
  { config :: !ClientConfig,
    env :: !ClientEnv,
    queue :: !(TBQueue AnalyticsEvent),
    worker :: !(Async ()),
    dropped :: !(TVar Int)
  }
  deriving stock (Generic)

data ClientError
  = DeliveryFailed !ServantClient.ClientError
  | DeliveryRejected !ProblemDetails
  deriving stock (Eq, Show)

-- NamedRoutes fields are type-family applications, so record-dot syntax cannot
-- see them. Use qualified selector application at call sites.
type instance AuthClientData (AuthProtect "kansoku-ingest") = Text

type instance AuthClientData (AuthProtect "kansoku-beacon") = ()

kansokuBeaconContext :: AuthenticatedRequest BeaconContext
kansokuBeaconContext = mkAuthenticatedRequest () (const id)

kansokuCredential :: Text -> AuthenticatedRequest IngestAuth
kansokuCredential token =
  mkAuthenticatedRequest token $ \value ->
    ClientRequest.addHeader "Authorization" ("Bearer " <> value)

ingestClient :: IngestRoutes (AsClientT ClientM)
ingestClient = ServantClient.client (Proxy @(NamedRoutes IngestRoutes))

schemaClient :: ClientM SchemaCatalog
schemaClient = ServantClient.client (Proxy @SchemaAPI)

newClient :: ClientConfig -> IO Client
newClient cfg = do
  parsed <- parseConfiguredBaseUrl cfg
  mgr <- maybe (HTTP.newManager HTTP.TLS.tlsManagerSettings) pure (cfg ^. #manager)
  queue <- newTBQueueIO (fromIntegral (max 1 (cfg ^. #bufferCapacity)))
  dropped <- newTVarIO 0
  let env = mkClientEnv mgr parsed
  worker <- async (flushLoop cfg env queue dropped)
  pure Client {config = cfg, env, queue, worker, dropped}

withClient :: ClientConfig -> (Client -> IO a) -> IO a
withClient cfg =
  bracket (newClient cfg) close

close :: Client -> IO ()
close clientHandle = do
  flush clientHandle
  cancel (clientHandle ^. #worker)

flush :: Client -> IO ()
flush clientHandle = do
  events <- atomically (drainQueue maxBound (clientHandle ^. #queue))
  traverse_
    (deliverBatch (clientHandle ^. #config) (clientHandle ^. #env) (clientHandle ^. #dropped))
    (chunksOf (max 1 (clientHandle ^. #config . #batchMaxSize)) events)

-- | Count events lost to buffer overflow, permanent delivery failure, or a
-- server-side per-event batch rejection.
droppedCount :: Client -> IO Int
droppedCount clientHandle =
  readTVarIO (clientHandle ^. #dropped)

-- | Fetch the public, versioned event schema catalog.
fetchSchemaCatalog :: Client -> IO (Either ClientError SchemaCatalog)
fetchSchemaCatalog clientHandle =
  first DeliveryFailed <$> runClientM schemaClient (clientHandle ^. #env)

track :: Client -> AnalyticsEvent -> IO ()
track clientHandle event = do
  written <-
    atomically $ do
      full <- isFullTBQueue (clientHandle ^. #queue)
      if full
        then pure False
        else writeTBQueue (clientHandle ^. #queue) event >> pure True
  unless written (atomically (modifyTVar' (clientHandle ^. #dropped) (+ 1)))

trackEvent :: Client -> EventIds -> Text -> [Pair] -> IO ()
trackEvent clientHandle ids name pairs =
  buildEvent (clientHandle ^. #config) ids name pairs >>= track clientHandle

-- | Track an event pinned to an explicit published schema version.
trackEventWithVersion :: Client -> EventIds -> Text -> Int -> [Pair] -> IO ()
trackEventWithVersion clientHandle ids name version pairs =
  buildEvent (clientHandle ^. #config) ids name pairs
    <&> (#schemaVersion ?~ version)
    >>= track clientHandle

-- | Governed current traits. Explicit v1 remains available for identity-only events.
identify :: Client -> Text -> Maybe Text -> [Pair] -> IO ()
identify clientHandle user anonId = identifyWithVersion clientHandle user anonId 2

identifyWithVersion :: Client -> Text -> Maybe Text -> Int -> [Pair] -> IO ()
identifyWithVersion clientHandle user anonId version traits =
  trackEventWithVersion clientHandle (emptyIds & #userId ?~ user & #anonymousId .~ anonId) "identify" version traits

identifyOnce :: Client -> Text -> Maybe Text -> [Pair] -> IO ()
identifyOnce clientHandle user anonId = identifyOnceWithVersion clientHandle user anonId 1

identifyOnceWithVersion :: Client -> Text -> Maybe Text -> Int -> [Pair] -> IO ()
identifyOnceWithVersion clientHandle user anonId version traits =
  trackEventWithVersion clientHandle (emptyIds & #userId ?~ user & #anonymousId .~ anonId) "identify_once" version traits

group :: Client -> EventIds -> Text -> [Pair] -> IO ()
group clientHandle ids organization pairs =
  buildEvent (clientHandle ^. #config) (ids & #organizationId ?~ organization) "group" pairs
    <&> (#schemaVersion ?~ 2)
    >>= track clientHandle

alias :: Client -> Text -> Text -> [Pair] -> IO ()
alias clientHandle previousId newId pairs =
  buildEvent
    (clientHandle ^. #config)
    (emptyIds & #anonymousId ?~ previousId & #userId ?~ newId)
    "alias"
    (pairs <> ["previousId" Aeson..= previousId, "newId" Aeson..= newId])
    >>= track clientHandle

buildEvent :: ClientConfig -> EventIds -> Text -> [Pair] -> IO AnalyticsEvent
buildEvent cfg ids name pairs = do
  eventId <- newEventId
  now <- getCurrentTime
  pure $
    baseEvent eventId (EventName name) Service now now
      & #sourceService
      .~ (cfg ^. #sourceService)
      & #anonymousId
      .~ (AnonymousId <$> ids ^. #anonymousId)
      & #userId
      .~ (UserId <$> ids ^. #userId)
      & #identifiers
      .~ (ids ^. #identifiers)
      & #organizationId
      .~ (OrganizationId <$> ids ^. #organizationId)
      & #accountId
      .~ (AccountId <$> ids ^. #accountId)
      & #sessionId
      .~ (SessionId <$> ids ^. #sessionId)
      & #properties
      .~ pairsObject pairs

newEventId :: IO EventId
newEventId =
  EventId . UUID.toText <$> UUID.nextRandom

pairsObject :: [Pair] -> Object
pairsObject =
  KeyMap.fromList

parseConfiguredBaseUrl :: ClientConfig -> IO BaseUrl
parseConfiguredBaseUrl cfg =
  parseBaseUrl (Text.unpack (cfg ^. #baseUrl))

flushLoop :: ClientConfig -> ClientEnv -> TBQueue AnalyticsEvent -> TVar Int -> IO ()
flushLoop cfg env queue dropped = do
  threadDelay (max 1 (cfg ^. #batchMaxIntervalMicros))
  events <- atomically (drainQueue (max 1 (cfg ^. #batchMaxSize)) queue)
  deliverBatch cfg env dropped events
  flushLoop cfg env queue dropped

drainQueue :: Int -> TBQueue AnalyticsEvent -> STM [AnalyticsEvent]
drainQueue limit queue =
  go limit []
  where
    go 0 acc = pure (reverse acc)
    go remaining acc = do
      next <- tryReadTBQueue queue
      case next of
        Nothing -> pure (reverse acc)
        Just event -> go (remaining - 1) (event : acc)

deliverBatch :: ClientConfig -> ClientEnv -> TVar Int -> [AnalyticsEvent] -> IO ()
deliverBatch _ _ _ [] = pure ()
deliverBatch cfg env dropped events = do
  result <- deliverWithRetry cfg env events
  case result of
    Right ack ->
      atomically (modifyTVar' dropped (+ length (ack ^. #rejected)))
    Left _ -> atomically (modifyTVar' dropped (+ length events))

deliverWithRetry :: ClientConfig -> ClientEnv -> [AnalyticsEvent] -> IO (Either ClientError BatchAck)
deliverWithRetry cfg env events =
  go 0
  where
    go attempt = do
      result <-
        runClientM
          (Ingest.postBatch ingestClient (kansokuCredential (cfg ^. #credential)) (Ingest.ingestEvent <$> events))
          env
      case result of
        Right (KansokuOk ack) -> pure (Right ack)
        Right (KansokuUnavailable envelope)
          | envelope ^. #retryable && attempt < cfg ^. #maxRetries -> do
              threadDelay (backoff attempt)
              go (attempt + 1)
          | otherwise -> pure (Left (DeliveryRejected envelope))
        Right (KansokuRateLimited envelope retryAfter)
          | envelope ^. #retryable && attempt < cfg ^. #maxRetries -> do
              let retryMicros = fromInteger (min (toInteger (maxBound :: Int)) (max 0 (toInteger retryAfter) * 1000000))
              threadDelay (max retryMicros (backoff attempt))
              go (attempt + 1)
          | otherwise -> pure (Left (DeliveryRejected envelope))
        Right (KansokuBadRequest envelope) -> pure (Left (DeliveryRejected envelope))
        Right (KansokuNotFound envelope) -> pure (Left (DeliveryRejected envelope))
        Right (KansokuTooLarge envelope) -> pure (Left (DeliveryRejected envelope))
        Left err
          | not (retryClientError err) -> pure (Left (DeliveryFailed err))
          | attempt >= cfg ^. #maxRetries -> pure (Left (DeliveryFailed err))
          | otherwise -> do
              threadDelay (backoff attempt)
              go (attempt + 1)

    backoff attempt =
      max 0 (cfg ^. #retryBaseDelayMicros) * (2 ^ attempt)

-- Authentication failures occur before MultiVerb and arrive as ClientError.
-- Only transport failures and retryable server failures merit another attempt.
retryClientError :: ServantClient.ClientError -> Bool
retryClientError = \case
  ServantClient.ConnectionError {} -> True
  ServantClient.FailureResponse _ response ->
    let status = statusCode (ClientResponse.responseStatusCode response)
     in status >= 500 && case Aeson.eitherDecode @ProblemDetails (ClientResponse.responseBody response) of
          Right problem -> problem ^. #retryable
          Left _ -> True
  _ -> False

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n values =
  let (prefix, suffix) = splitAt n values
   in prefix : chunksOf n suffix
