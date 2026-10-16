{-# LANGUAGE TypeApplications #-}

module Kansoku.Ingest.HandlerSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.List qualified as List
import Data.UUID qualified as UUID
import Kansoku.Api.Response (problem)
import Kansoku.Auth.Types
import Kansoku.Event
import Kansoku.Ingest.Api (BatchAck (..), RejectedEvent (..))
import Kansoku.Ingest.Handler (batchLengthError, partitionBatch, stampAuthenticatedEvent)
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Ingest.Handler" $ do
  it "partitions valid and invalid events while preserving order and indices" $ do
    let submitted =
          [ event "evt-0" "custom-valid",
            event "" "custom-valid",
            event "evt-2" "custom-valid",
            event "evt-3" "",
            event "evt-4" "custom-valid"
          ]
        (acceptedEvents, rejectedEvents) = partitionBatch submitted
    (unEventId . (^. #eventId) <$> acceptedEvents)
      `shouldBe` ["evt-0", "evt-2", "evt-4"]
    rejectedEvents
      `shouldBe` [ RejectedEvent
                     { index = 1,
                       eventId = Nothing,
                       errors = ["eventId must not be empty"]
                     },
                   RejectedEvent
                     { index = 3,
                       eventId = Just "evt-3",
                       errors = ["eventName must not be empty"]
                     }
                 ]

  it "keeps a compatible sibling and rejects only the incompatible JSON index" $ do
    let object = KeyMap.fromList [("a.b", Aeson.Number 1), ("a", Aeson.object ["b" Aeson..= (2 :: Int)])]
        bad = event "bad" "custom-valid" & #properties .~ object
        good = event "good" "custom-valid"
    partitionBatch [good, bad] `shouldBe` ([good], [RejectedEvent 1 (Just "bad") [renderValidationError (IncompatibleJsonPaths "properties")]])

  it "handles all-invalid and empty batches" $ do
    partitionBatch [event "" "", event "" "custom-valid"]
      `shouldBe` ( [],
                   [ RejectedEvent 0 Nothing ["eventId must not be empty", "eventName must not be empty"],
                     RejectedEvent 1 Nothing ["eventId must not be empty"]
                   ]
                 )
    partitionBatch [] `shouldBe` ([], [])

  it "pins the BatchAck JSON keys and round-trip" $ do
    let ack = BatchAck 3 [RejectedEvent 1 Nothing ["eventId must not be empty"]]
        encoded = Aeson.encode ack
    Aeson.eitherDecode @BatchAck encoded `shouldBe` Right ack
    case Aeson.decode @Aeson.Value encoded of
      Just (Aeson.Object object) ->
        List.sort (Key.toText <$> KeyMap.keys object) `shouldBe` ["accepted", "rejected"]
      decoded -> expectationFailure ("expected object, got " <> show decoded)

  it "rejects only batches above the configured length" $ do
    batchLengthError 500 500 `shouldBe` Nothing
    batchLengthError 500 501
      `shouldBe` Just
        (problem 413 "batch_too_large" "batch of 501 events exceeds the limit of 500")

  it "renders every validation error as human-readable text" $ do
    renderValidationError EmptyEventId `shouldBe` "eventId must not be empty"
    renderValidationError EmptyEventName `shouldBe` "eventName must not be empty"
    renderValidationError (ReceivedBeforeOccurred occurred received)
      `shouldBe` "receivedAt (2026-07-19T09:00:00Z) precedes occurredAt (2026-07-19T10:00:00Z); occurredAt is in the future relative to the server clock"
    renderValidationError (UnknownIdentifierKind "mac_address" allowedIdentifierKindNames)
      `shouldBe` "identifier kind 'mac_address' is not supported; allowed kinds: cookie, device, fingerprint, email_sha256, email_hmac"
    renderValidationError (EmptyIdentifierValue "fingerprint")
      `shouldBe` "identifier 'fingerprint' must not be empty"
    renderValidationError (IdentifierValueTooLong "device" 257 256)
      `shouldBe` "identifier 'device' is 257 characters; maximum is 256"
    renderValidationError (IdentifierValueBadCharset "email_sha256")
      `shouldBe` "identifier 'email_sha256' must contain only printable non-space ASCII characters"
    renderValidationError (MissingRequiredProperty (EventName "page_view") "url")
      `shouldBe` "event 'page_view': missing required property 'url'"
    renderValidationError (WrongPropertyType (EventName "page_view") "url" PTString)
      `shouldBe` "event 'page_view': property 'url' must be of type string"
    renderValidationError (WrongPropertyType (EventName "event") "number" PTNumber)
      `shouldBe` "event 'event': property 'number' must be of type number"
    renderValidationError (WrongPropertyType (EventName "event") "bool" PTBool)
      `shouldBe` "event 'event': property 'bool' must be of type boolean"
    renderValidationError (WrongPropertyType (EventName "event") "object" PTObject)
      `shouldBe` "event 'event': property 'object' must be of type object"
    renderValidationError (WrongPropertyType (EventName "event") "array" PTArray)
      `shouldBe` "event 'event': property 'array' must be of type array"
    renderValidationError (WrongPropertyType (EventName "event") "anything" PTAny)
      `shouldBe` "event 'event': property 'anything' must be of type any"

  it "overwrites a client-supplied account with the authenticated account" $ do
    let raw = event "evt-stamped" "custom-valid" & #accountId ?~ AccountId "acct_spoofed"
        principal =
          AuthenticatedPrincipal
            { keyId = ApiKeyId UUID.nil,
              kind = WriteKey,
              accountId = AccountId "acct_authoritative"
            }
        stamped = stampAuthenticatedEvent received principal raw
    stamped ^. #receivedAt `shouldBe` received
    stamped ^. #accountId `shouldBe` Just (AccountId "acct_authoritative")
  where
    occurred = read "2026-07-19 10:00:00 UTC"
    received = read "2026-07-19 09:00:00 UTC"

event :: Text -> Text -> AnalyticsEvent
event eventIdentifier name =
  baseEvent
    (EventId eventIdentifier)
    (EventName name)
    Service
    observedAt
    observedAt

observedAt :: UTCTime
observedAt = read "2026-07-19 08:00:00 UTC"
