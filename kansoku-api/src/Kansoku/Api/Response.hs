{-# LANGUAGE DataKinds #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Shared response machinery for every Kansoku API slice.
module Kansoku.Api.Response
  ( AcceptedResponses,
    ErrorEnvelopeWire (..),
    KansokuResult (..),
    OkResponses,
    badRequest,
    notFound,
    tooLarge,
    unavailable,
  )
where

import Data.SOP (I (..), NS (..))
import GHC.TypeLits (Symbol)
import Kansoku.Prelude
import Servant.API.MultiVerb (AsUnion (..), Respond)

-- | The one error-body shape returned across the service.
data ErrorEnvelopeWire = ErrorEnvelopeWire
  { code :: !Text,
    message :: !Text,
    retryable :: !Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | What every analytics handler returns. The success status is selected by
-- the route's response list; error constructors map to fixed statuses.
data KansokuResult a
  = KansokuOk a
  | KansokuBadRequest !ErrorEnvelopeWire
  | KansokuNotFound !ErrorEnvelopeWire
  | KansokuTooLarge !ErrorEnvelopeWire
  | KansokuUnavailable !ErrorEnvelopeWire
  deriving stock (Generic, Eq, Show)

type OkResponses (desc :: Symbol) a =
  '[ Respond 200 desc a,
     Respond 400 "Malformed request" ErrorEnvelopeWire,
     Respond 404 "Not found" ErrorEnvelopeWire,
     Respond 413 "Payload too large" ErrorEnvelopeWire,
     Respond 503 "Storage unavailable" ErrorEnvelopeWire
   ]

type AcceptedResponses (desc :: Symbol) a =
  '[ Respond 202 desc a,
     Respond 400 "Malformed request" ErrorEnvelopeWire,
     Respond 404 "Not found" ErrorEnvelopeWire,
     Respond 413 "Payload too large" ErrorEnvelopeWire,
     Respond 503 "Storage unavailable" ErrorEnvelopeWire
   ]

-- These instances deliberately spell out the positional mapping. The final
-- empty case is an exhaustiveness witness: growing either response list makes
-- the instance stop compiling until the result mapping is updated.
instance
  AsUnion
    '[ Respond 200 desc a,
       Respond 400 "Malformed request" ErrorEnvelopeWire,
       Respond 404 "Not found" ErrorEnvelopeWire,
       Respond 413 "Payload too large" ErrorEnvelopeWire,
       Respond 503 "Storage unavailable" ErrorEnvelopeWire
     ]
    (KansokuResult a)
  where
  toUnion = \case
    KansokuOk value -> Z (I value)
    KansokuBadRequest err -> S (Z (I err))
    KansokuNotFound err -> S (S (Z (I err)))
    KansokuTooLarge err -> S (S (S (Z (I err))))
    KansokuUnavailable err -> S (S (S (S (Z (I err)))))
  fromUnion = \case
    Z (I value) -> KansokuOk value
    S (Z (I err)) -> KansokuBadRequest err
    S (S (Z (I err))) -> KansokuNotFound err
    S (S (S (Z (I err)))) -> KansokuTooLarge err
    S (S (S (S (Z (I err))))) -> KansokuUnavailable err
    S (S (S (S (S impossible)))) -> case impossible of {}

instance
  AsUnion
    '[ Respond 202 desc a,
       Respond 400 "Malformed request" ErrorEnvelopeWire,
       Respond 404 "Not found" ErrorEnvelopeWire,
       Respond 413 "Payload too large" ErrorEnvelopeWire,
       Respond 503 "Storage unavailable" ErrorEnvelopeWire
     ]
    (KansokuResult a)
  where
  toUnion = \case
    KansokuOk value -> Z (I value)
    KansokuBadRequest err -> S (Z (I err))
    KansokuNotFound err -> S (S (Z (I err)))
    KansokuTooLarge err -> S (S (S (Z (I err))))
    KansokuUnavailable err -> S (S (S (S (Z (I err)))))
  fromUnion = \case
    Z (I value) -> KansokuOk value
    S (Z (I err)) -> KansokuBadRequest err
    S (S (Z (I err))) -> KansokuNotFound err
    S (S (S (Z (I err)))) -> KansokuTooLarge err
    S (S (S (S (Z (I err))))) -> KansokuUnavailable err
    S (S (S (S (S impossible)))) -> case impossible of {}

badRequest :: Text -> Text -> ErrorEnvelopeWire
badRequest code message = ErrorEnvelopeWire {code, message, retryable = False}

notFound :: Text -> Text -> ErrorEnvelopeWire
notFound code message = ErrorEnvelopeWire {code, message, retryable = False}

tooLarge :: Text -> Text -> ErrorEnvelopeWire
tooLarge code message = ErrorEnvelopeWire {code, message, retryable = False}

unavailable :: Text -> Text -> ErrorEnvelopeWire
unavailable code message = ErrorEnvelopeWire {code, message, retryable = True}
