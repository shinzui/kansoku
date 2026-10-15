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
    propertyPatternText,
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
data PropertyPattern = SqlNamePattern | NonEmptyStringPattern | NonNegativeNumberPattern
  deriving stock (Generic, Eq, Show)

propertyPatternText :: PropertyPattern -> Text
propertyPatternText = \case
  SqlNamePattern -> "[a-z0-9_.:-]{1,128}"
  NonEmptyStringPattern -> "nonempty string"
  NonNegativeNumberPattern -> "number >= 0"

data PropertySpec = PropertySpec
  { name :: !Text,
    propertyType :: !PropertyType,
    required :: !Bool,
    validationPattern :: !(Maybe PropertyPattern),
    description :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

data EventSchema = EventSchema
  { eventName :: !EventName,
    version :: !Int,
    note :: !Text,
    properties :: ![PropertySpec]
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
registerSchema schema@EventSchema {eventName, version = newVersion} (EventRegistry registry) =
  EventRegistry (Map.alter upsert eventName registry)
  where
    upsert Nothing = Just (schema :| [])
    upsert (Just versions) =
      Just
        ( NonEmpty.fromList
            ( sortOn
                versionOf
                (schema : filter ((/= newVersion) . versionOf) (NonEmpty.toList versions))
            )
        )

lookupVersions :: EventName -> EventRegistry -> Maybe (NonEmpty EventSchema)
lookupVersions name (EventRegistry registry) = Map.lookup name registry

lookupSchemaVersion :: EventName -> Int -> EventRegistry -> Maybe EventSchema
lookupSchemaVersion name version registry =
  find ((== version) . versionOf) . NonEmpty.toList =<< lookupVersions name registry

latestSchema :: EventName -> EventRegistry -> Maybe EventSchema
latestSchema name registry = NonEmpty.last <$> lookupVersions name registry

knownVersions :: EventName -> EventRegistry -> [Int]
knownVersions name registry =
  maybe [] (fmap versionOf . NonEmpty.toList) (lookupVersions name registry)

versionOf :: EventSchema -> Int
versionOf EventSchema {version} = version

defaultRegistry :: EventRegistry
defaultRegistry =
  foldr
    registerSchema
    emptyRegistry
    [ EventSchema
        (EventName "alias")
        1
        "Bind an anonymous identifier to a user; top-level IDs must match. Works with SDK alias helpers."
        [ PropertySpec "previousId" PTString True (Just NonEmptyStringPattern) (Just "Anonymous identifier; must equal anonymousId."),
          PropertySpec "newId" PTString True (Just NonEmptyStringPattern) (Just "User identifier; must equal userId.")
        ],
      EventSchema (EventName "group") 1 "Stamp organization context; requires a nonempty top-level organizationId." [],
      EventSchema
        (EventName "page_leave")
        1
        "Page lifecycle event; not engagement. Top-level URL identifies the page."
        [PropertySpec "durationMs" PTNumber True (Just NonNegativeNumberPattern) (Just "Observed page duration in milliseconds.")],
      EventSchema
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
