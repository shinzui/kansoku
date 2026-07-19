-- | In-memory event schema registry for extra validation of known event names.
module Kansoku.Event.Registry
  ( EventRegistry (..),
    EventSchema (..),
    PropertyPattern (..),
    PropertySpec (..),
    PropertyType (..),
    defaultRegistry,
    emptyRegistry,
    knownVersions,
    latestSchema,
    lookupSchemaVersion,
    lookupVersions,
    registerSchema,
  )
where

import Data.List (find, sortOn)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Kansoku.Event.Types (EventName (..))
import Kansoku.Prelude

-- | A loose description of an expected property's JSON type.
data PropertyType = PTString | PTNumber | PTBool | PTObject | PTArray | PTAny
  deriving stock (Generic, Eq, Show)

-- | A syntactic constraint applied after a property's JSON type is validated.
data PropertyPattern = SqlNamePattern
  deriving stock (Generic, Eq, Show)

data PropertySpec = PropertySpec
  { propName :: !Text,
    propType :: !PropertyType,
    propRequired :: !Bool,
    propPattern :: !(Maybe PropertyPattern),
    propDescription :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

data EventSchema = EventSchema
  { schemaEventName :: !EventName,
    schemaVersion :: !Int,
    schemaNote :: !Text,
    schemaProperties :: ![PropertySpec]
  }
  deriving stock (Generic, Eq, Show)

-- | Every version list is ascending and has exactly the versions 1..n. Released
-- versions are immutable; replacing an existing pair is intended for
-- idempotent construction, not in-place production schema edits.
newtype EventRegistry = EventRegistry (Map EventName (NonEmpty EventSchema))
  deriving stock (Generic, Eq, Show)

emptyRegistry :: EventRegistry
emptyRegistry = EventRegistry Map.empty

registerSchema :: EventSchema -> EventRegistry -> EventRegistry
registerSchema schema (EventRegistry registry) =
  EventRegistry (Map.alter upsert (schemaEventName schema) registry)
  where
    upsert Nothing = Just (schema :| [])
    upsert (Just versions) =
      Just
        ( NonEmpty.fromList
            ( sortOn
                schemaVersion
                (schema : filter ((/= schemaVersion schema) . schemaVersion) (NonEmpty.toList versions))
            )
        )

lookupVersions :: EventName -> EventRegistry -> Maybe (NonEmpty EventSchema)
lookupVersions name (EventRegistry registry) = Map.lookup name registry

lookupSchemaVersion :: EventName -> Int -> EventRegistry -> Maybe EventSchema
lookupSchemaVersion name version registry =
  find ((== version) . schemaVersion) . NonEmpty.toList =<< lookupVersions name registry

latestSchema :: EventName -> EventRegistry -> Maybe EventSchema
latestSchema name registry = NonEmpty.last <$> lookupVersions name registry

knownVersions :: EventName -> EventRegistry -> [Int]
knownVersions name registry =
  maybe [] (fmap schemaVersion . NonEmpty.toList) (lookupVersions name registry)

defaultRegistry :: EventRegistry
defaultRegistry =
  foldr
    registerSchema
    emptyRegistry
    [ EventSchema
        (EventName "page_view")
        1
        initialSchemaNote
        [plainProperty "url" PTString True "Full URL of the viewed page."],
      EventSchema
        (EventName "session_start")
        1
        initialSchemaNote
        [plainProperty "sessionId" PTString True "Client-generated session identifier."],
      EventSchema
        (EventName "identify")
        1
        initialSchemaNote
        [],
      EventSchema
        (EventName "user_registered")
        1
        initialSchemaNote
        [plainProperty "userId" PTString True "Identifier of the newly registered user."],
      EventSchema
        (EventName "subscription_started")
        1
        initialSchemaNote
        [ plainProperty "plan" PTString True "Plan identifier the subscription started on.",
          plainProperty "amount" PTNumber False "Monetary amount of the subscription, in the account's currency."
        ],
      EventSchema
        (EventName "payment_completed")
        1
        initialSchemaNote
        [ plainProperty "amount" PTNumber True "Monetary amount of the completed payment, in the account's currency.",
          plainProperty "plan" PTString False "Plan associated with the completed payment."
        ],
      EventSchema
        (EventName "feature_used")
        1
        initialSchemaNote
        [plainProperty "feature" PTString True "Stable identifier of the feature used."],
      -- Emit an exposure when a user is shown a variant, not merely assigned
      -- one. Re-exposures are allowed because analytics count unique users.
      EventSchema
        (EventName "experiment_viewed")
        1
        initialSchemaNote
        [ sqlNameProperty "experiment" "Stable identifier of the experiment.",
          sqlNameProperty "variant" "Variant shown to the user."
        ]
    ]

initialSchemaNote :: Text
initialSchemaNote = "Initial schema (kansoku MVP)."

plainProperty :: Text -> PropertyType -> Bool -> Text -> PropertySpec
plainProperty name propertyType required description =
  PropertySpec name propertyType required Nothing (Just description)

sqlNameProperty :: Text -> Text -> PropertySpec
sqlNameProperty name description =
  PropertySpec name PTString True (Just SqlNamePattern) (Just description)
