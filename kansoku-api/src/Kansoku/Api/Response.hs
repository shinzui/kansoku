{-# LANGUAGE DataKinds #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Shared response machinery for every Kansoku API slice.
module Kansoku.Api.Response
  ( AcceptedResponses,
    ProblemDetails (..),
    KansokuResult (..),
    ProblemJSON,
    problemFieldName,
    problem,
    problemCatalog,
    OkResponses,
    badRequest,
    notFound,
    tooLarge,
    rateLimited,
    unauthorized,
    unavailable,
    forbidden,
  )
where

import Data.Aeson qualified as Aeson
import Data.SOP (I (..), NS (..))
import Data.Text.Encoding qualified as Text.Encoding
import GHC.TypeLits (Symbol)
import Kansoku.Prelude
import Network.HTTP.Media ((//))
import Network.HTTP.Types.Status (status400, status401, status403, status404, status405, status406, status413, status415, status429, status500, status503, statusMessage)
import Servant.API (Accept (..), Header, JSON, MimeRender (..), MimeUnrender (..))
import Servant.API.MultiVerb (AsUnion (..), RespondAs, WithHeaders)

-- | RFC 9457 problem document. `about:blank` uses the HTTP status phrase.
data ProblemDetails = ProblemDetails
  { problemType :: !Text,
    title :: !Text,
    status :: !Int,
    detail :: !Text,
    code :: !Text,
    retryable :: !Bool
  }
  deriving stock (Generic, Eq, Show)

problemFieldName :: String -> String
problemFieldName "problemType" = "type"
problemFieldName field = field

instance ToJSON ProblemDetails where
  toJSON = Aeson.genericToJSON Aeson.defaultOptions {Aeson.fieldLabelModifier = problemFieldName}

instance FromJSON ProblemDetails where
  parseJSON = Aeson.genericParseJSON Aeson.defaultOptions {Aeson.fieldLabelModifier = problemFieldName}

-- | Errors have a distinct media type; successful payloads remain JSON.
data ProblemJSON

instance Accept ProblemJSON where
  contentType _ = "application" // "problem+json"

instance MimeRender ProblemJSON ProblemDetails where
  mimeRender _ = Aeson.encode

instance MimeUnrender ProblemJSON ProblemDetails where
  mimeUnrender _ = Aeson.eitherDecode

-- | What every analytics handler returns. The success status is selected by
-- the route's response list; error constructors map to fixed statuses.
data KansokuResult a
  = KansokuOk a
  | KansokuBadRequest !ProblemDetails
  | KansokuNotFound !ProblemDetails
  | KansokuTooLarge !ProblemDetails
  | KansokuUnavailable !ProblemDetails
  | KansokuRateLimited !ProblemDetails !Int
  deriving stock (Generic, Eq, Show, Functor)

type RateLimitedResponse =
  WithHeaders
    '[Header "Retry-After" Int]
    (ProblemDetails, Int)
    (RespondAs ProblemJSON 429 "Rate limited" ProblemDetails)

type OkResponses (desc :: Symbol) a =
  '[ RespondAs JSON 200 desc a,
     RespondAs ProblemJSON 400 "Malformed request" ProblemDetails,
     RespondAs ProblemJSON 404 "Not found" ProblemDetails,
     RespondAs ProblemJSON 413 "Payload too large" ProblemDetails,
     RespondAs ProblemJSON 503 "Storage unavailable" ProblemDetails,
     RateLimitedResponse
   ]

type AcceptedResponses (desc :: Symbol) a =
  '[ RespondAs JSON 202 desc a,
     RespondAs ProblemJSON 400 "Malformed request" ProblemDetails,
     RespondAs ProblemJSON 404 "Not found" ProblemDetails,
     RespondAs ProblemJSON 413 "Payload too large" ProblemDetails,
     RespondAs ProblemJSON 503 "Storage unavailable" ProblemDetails,
     RateLimitedResponse
   ]

-- These instances deliberately spell out the positional mapping. The final
-- empty case is an exhaustiveness witness: growing either response list makes
-- the instance stop compiling until the result mapping is updated.
instance
  AsUnion
    '[ RespondAs JSON 200 desc a,
       RespondAs ProblemJSON 400 "Malformed request" ProblemDetails,
       RespondAs ProblemJSON 404 "Not found" ProblemDetails,
       RespondAs ProblemJSON 413 "Payload too large" ProblemDetails,
       RespondAs ProblemJSON 503 "Storage unavailable" ProblemDetails,
       RateLimitedResponse
     ]
    (KansokuResult a)
  where
  toUnion = \case
    KansokuOk value -> Z (I value)
    KansokuBadRequest err -> S (Z (I err))
    KansokuNotFound err -> S (S (Z (I err)))
    KansokuTooLarge err -> S (S (S (Z (I err))))
    KansokuUnavailable err -> S (S (S (S (Z (I err)))))
    KansokuRateLimited err delay -> S (S (S (S (S (Z (I (err, delay)))))))
  fromUnion = \case
    Z (I value) -> KansokuOk value
    S (Z (I err)) -> KansokuBadRequest err
    S (S (Z (I err))) -> KansokuNotFound err
    S (S (S (Z (I err)))) -> KansokuTooLarge err
    S (S (S (S (Z (I err))))) -> KansokuUnavailable err
    S (S (S (S (S (Z (I (err, delay))))))) -> KansokuRateLimited err delay
    S (S (S (S (S (S impossible))))) -> case impossible of {}

instance
  AsUnion
    '[ RespondAs JSON 202 desc a,
       RespondAs ProblemJSON 400 "Malformed request" ProblemDetails,
       RespondAs ProblemJSON 404 "Not found" ProblemDetails,
       RespondAs ProblemJSON 413 "Payload too large" ProblemDetails,
       RespondAs ProblemJSON 503 "Storage unavailable" ProblemDetails,
       RateLimitedResponse
     ]
    (KansokuResult a)
  where
  toUnion = \case
    KansokuOk value -> Z (I value)
    KansokuBadRequest err -> S (Z (I err))
    KansokuNotFound err -> S (S (Z (I err)))
    KansokuTooLarge err -> S (S (S (Z (I err))))
    KansokuUnavailable err -> S (S (S (S (Z (I err)))))
    KansokuRateLimited err delay -> S (S (S (S (S (Z (I (err, delay)))))))
  fromUnion = \case
    Z (I value) -> KansokuOk value
    S (Z (I err)) -> KansokuBadRequest err
    S (S (Z (I err))) -> KansokuNotFound err
    S (S (S (Z (I err)))) -> KansokuTooLarge err
    S (S (S (S (Z (I err))))) -> KansokuUnavailable err
    S (S (S (S (S (Z (I (err, delay))))))) -> KansokuRateLimited err delay
    S (S (S (S (S (S impossible))))) -> case impossible of {}

-- | Central status/title/retry policy. Callers supply a stable code and safe detail.
problem :: Int -> Text -> Text -> ProblemDetails
problem status code detail =
  ProblemDetails
    { problemType = "about:blank",
      title =
        Text.Encoding.decodeUtf8
          ( statusMessage
              ( case status of
                  400 -> status400
                  401 -> status401
                  403 -> status403
                  404 -> status404
                  405 -> status405
                  406 -> status406
                  413 -> status413
                  415 -> status415
                  429 -> status429
                  503 -> status503
                  _ -> status500
              )
          ),
      status,
      detail,
      code,
      retryable = status == 503 || status == 429
    }

badRequest, notFound, tooLarge, rateLimited, unauthorized, forbidden, unavailable :: Text -> Text -> ProblemDetails
badRequest = catalogProblem 400
notFound = catalogProblem 404
tooLarge = catalogProblem 413
rateLimited = catalogProblem 429
unauthorized = catalogProblem 401
forbidden = catalogProblem 403
unavailable = catalogProblem 503

-- | Stable public codes and their HTTP statuses. Titles and retry policy come
-- from 'problem'; human-readable detail is supplied by the failure producer.
problemCatalog :: [(Text, Int)]
problemCatalog =
  [ ("invalid_cohort", 400),
    ("cohort_not_found", 404),
    ("cohort_store_unavailable", 503),
    ("invalid_date_range", 400),
    ("query_range_too_large", 400),
    ("too_many_funnel_steps", 400),
    ("too_many_retention_days", 400),
    ("metric_result_too_large", 400),
    ("malformed_request", 400),
    ("validation_failed", 400),
    ("event_id_conflict", 400),
    ("invalid_funnel_steps", 400),
    ("invalid_funnel_step", 400),
    ("invalid_funnel_window", 400),
    ("invalid_retention_days", 400),
    ("invalid_experiment_time_grain", 400),
    ("invalid_experiment_name", 400),
    ("invalid_event_name", 400),
    ("invalid_conversion_event", 400),
    ("unknown_property", 400),
    ("invalid_property_filter", 400),
    ("invalid_property", 400),
    ("invalid_group_by", 400),
    ("invalid_metric_definition", 400),
    ("unauthorized", 401),
    ("forbidden", 403),
    ("not_found", 404),
    ("metric_not_found", 404),
    ("not_implemented", 404),
    ("method_not_allowed", 405),
    ("not_acceptable", 406),
    ("payload_too_large", 413),
    ("batch_too_large", 413),
    ("rate_limited", 429),
    ("unsupported_media_type", 415),
    ("internal_error", 500),
    ("auth_store_unavailable", 503),
    ("queue_unavailable", 503),
    ("clickhouse_unavailable", 503)
  ]

catalogProblem :: Int -> Text -> Text -> ProblemDetails
catalogProblem fallbackStatus code = problem (fromMaybe fallbackStatus (lookup code problemCatalog)) code
