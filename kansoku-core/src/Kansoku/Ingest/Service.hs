-- | Authenticated ingest shared by every transport, including beacon adaptation.
module Kansoku.Ingest.Service
  ( IngestService,
    IngestTransport (..),
    newIngestService,
    newIngestServiceWithClock,
    submitIngest,
    ingestRequestContext,
    batchLengthError,
    stampAuthenticatedEvent,
  )
where

import Data.Foldable (forM_)
import Data.Generics.Labels ()
import Data.List (nub)
import Data.Text qualified as Text
import Effectful (runEff)
import Hasql.Pool qualified as Pool
import Kansoku.Api.Response
import Kansoku.Auth.Types (AuthenticatedPrincipal)
import Kansoku.Config (Config)
import Kansoku.Event
import Kansoku.Ingest.Acceptance
import Kansoku.Ingest.Api (IngestEvent (..))
import Kansoku.Ingest.GeoIP (newCountryLookup)
import Kansoku.Ingest.Quarantine (captureRejections)
import Kansoku.Ingest.QueuedEvent (enrichedQueuedEvent)
import Kansoku.Ingest.RateLimit
import Kansoku.Ingest.RequestContext (IngestRequestContext, captureRequestContext)
import Kansoku.Ingest.Timestamp
import Kansoku.Logging (logError, runLogStderr)
import Kansoku.Observability (PipelineMetrics)
import Kansoku.Prelude
import Network.Wai (Request)
import Pgmq.Types (QueueName)
import Prometheus qualified as P
import Servant (Handler)

data IngestTransport = Single | Batch | Beacon
  deriving stock (Eq, Show)

data IngestService = IngestService Config PipelineMetrics Pool.Pool QueueName RateLimiter (Request -> IO IngestRequestContext)

newIngestService :: Config -> PipelineMetrics -> Pool.Pool -> QueueName -> IO IngestService
newIngestService cfg metrics pool queue = do
  validateAdmissionConfig cfg
  limiter <- newRateLimiter (RatePolicy (cfg ^. #ingestRatePerSec) (cfg ^. #ingestRateBurst) 10000)
  lookupCountry <- newCountryLookup (cfg ^. #ingestGeoipDb) (cfg ^. #ingestTrustedProxyCidrs)
  pure (IngestService cfg metrics pool queue limiter (captureRequestContext lookupCountry))

newIngestServiceWithClock :: IO Double -> Config -> PipelineMetrics -> Pool.Pool -> QueueName -> IO IngestService
newIngestServiceWithClock clock cfg metrics pool queue = do
  validateAdmissionConfig cfg
  limiter <- newRateLimiterWithClock (RatePolicy (cfg ^. #ingestRatePerSec) (cfg ^. #ingestRateBurst) 10000) clock
  lookupCountry <- newCountryLookup (cfg ^. #ingestGeoipDb) (cfg ^. #ingestTrustedProxyCidrs)
  pure (IngestService cfg metrics pool queue limiter (captureRequestContext lookupCountry))

ingestRequestContext :: IngestService -> Request -> IO IngestRequestContext
ingestRequestContext (IngestService _ _ _ _ _ capture) = capture

validateAdmissionConfig :: Config -> IO ()
validateAdmissionConfig cfg =
  when (cfg ^. #ingestRatePerSec > 0 && cfg ^. #ingestRateBurst < cfg ^. #ingestMaxBatchLength) $
    fail "enabled ingest burst must cover the maximum batch length"

-- | Auth and bounded decoding precede this call. Semantic batch bounds precede
-- admission; every event within those bounds, including invalid schema entries
-- and identical retries, charges this process's shared credential bucket.
submitIngest :: IngestService -> IngestTransport -> AuthenticatedPrincipal -> IngestRequestContext -> [IngestEvent] -> Handler (KansokuResult [Acceptance])
submitIngest (IngestService cfg metrics pool queueName limiter _) channel principal request raw =
  case batchLengthError (cfg ^. #ingestMaxBatchLength) (length raw) of
    Just err -> pure (KansokuTooLarge err)
    Nothing -> do
      admission <- liftIO $ admit limiter (principal ^. #keyId) (length raw)
      case admission of
        Left retryAfter -> do
          liftIO $ P.withLabel (metrics ^. #ingestRateLimitedRequestsTotal) transport P.incCounter
          pure (KansokuRateLimited (rateLimited "rate_limited" "ingest credential rate limit exceeded") retryAfter)
        Right () -> acceptedRequest
  where
    transport = case channel of Single -> "single"; Batch -> "batch"; Beacon -> "beacon"
    acceptedRequest = do
      now <- liftIO getCurrentTime
      let validate input =
            let (adjusted, adjustment) = normalizeOccurredAt (fromIntegral (cfg ^. #ingestFutureToleranceSec)) now (stampAuthenticatedEvent now principal (parsedEvent input))
             in (\event -> (enrichedQueuedEvent request event, adjustment)) <$> validateEvent adjusted
      result <- liftIO $ acceptQueuedBatch pool queueName (principal ^. #accountId) validate raw
      case result of
        Left _ -> do
          liftIO . runEff . runLogStderr $ logError "ingest enqueue failed"
          pure (KansokuUnavailable (unavailable "queue_unavailable" "analytics queue is unavailable"))
        Right outcomes -> do
          liftIO $ forM_ outcomes $ \case
            NewEvent _ adjustment -> do
              accepted
              P.withLabel (metrics ^. #ingestNewlyQueuedTotal) transport P.incCounter
              forM_ adjustment $ \kind ->
                P.withLabel
                  (metrics ^. #ingestTimestampAdjustmentsTotal)
                  (case kind of SkewCorrected -> "skew_corrected"; Clamped -> "clamped", transport)
                  P.incCounter
            Replay -> accepted
            Rejected errs -> do
              P.withLabel (metrics ^. #ingestEventsTotal) ("rejected", transport) P.incCounter
              forM_ (nub (validationReason <$> errs)) $ \reason ->
                P.withLabel (metrics ^. #ingestRejectionsTotal) (reason, transport) P.incCounter
          liftIO $
            captureRejections
              cfg
              metrics
              transport
              (principal ^. #accountId)
              now
              [(parsedEvent input, originalPayload input, errs) | (input, Rejected errs) <- zip raw outcomes]
          pure (KansokuOk outcomes)
    accepted = P.withLabel (metrics ^. #ingestEventsTotal) ("accepted", transport) P.incCounter

stampAuthenticatedEvent :: UTCTime -> AuthenticatedPrincipal -> AnalyticsEvent -> AnalyticsEvent
stampAuthenticatedEvent receivedAt principal event = event & #receivedAt .~ receivedAt & #accountId ?~ (principal ^. #accountId)

batchLengthError :: Int -> Int -> Maybe ProblemDetails
batchLengthError maxBatchLength actualLength
  | actualLength > maxBatchLength = Just (tooLarge "batch_too_large" ("batch of " <> Text.pack (show actualLength) <> " events exceeds the limit of " <> Text.pack (show maxBatchLength)))
  | otherwise = Nothing
