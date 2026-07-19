-- | In-memory event schema registry for extra validation of known event names.
module Kansoku.Event.Registry
  ( EventRegistry (..),
    EventSchema (..),
    PropertyPattern (..),
    PropertySpec (..),
    PropertyType (..),
    defaultRegistry,
    emptyRegistry,
    lookupSchema,
    registerSchema,
  )
where

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
    propPattern :: !(Maybe PropertyPattern)
  }
  deriving stock (Generic, Eq, Show)

data EventSchema = EventSchema
  { schemaEventName :: !EventName,
    schemaProperties :: ![PropertySpec]
  }
  deriving stock (Generic, Eq, Show)

newtype EventRegistry = EventRegistry (Map EventName EventSchema)
  deriving stock (Generic, Eq, Show)

emptyRegistry :: EventRegistry
emptyRegistry = EventRegistry Map.empty

registerSchema :: EventSchema -> EventRegistry -> EventRegistry
registerSchema s (EventRegistry m) = EventRegistry (Map.insert (schemaEventName s) s m)

lookupSchema :: EventName -> EventRegistry -> Maybe EventSchema
lookupSchema n (EventRegistry m) = Map.lookup n m

defaultRegistry :: EventRegistry
defaultRegistry =
  foldr
    registerSchema
    emptyRegistry
    [ EventSchema
        (EventName "page_view")
        [plainProperty "url" PTString True],
      EventSchema
        (EventName "session_start")
        [plainProperty "sessionId" PTString True],
      EventSchema
        (EventName "identify")
        [],
      EventSchema
        (EventName "user_registered")
        [plainProperty "userId" PTString True],
      EventSchema
        (EventName "subscription_started")
        [ plainProperty "plan" PTString True,
          plainProperty "amount" PTNumber False
        ],
      EventSchema
        (EventName "payment_completed")
        [ plainProperty "amount" PTNumber True,
          plainProperty "plan" PTString False
        ],
      EventSchema
        (EventName "feature_used")
        [plainProperty "feature" PTString True],
      -- Emit an exposure when a user is shown a variant, not merely assigned
      -- one. Re-exposures are allowed because analytics count unique users.
      EventSchema
        (EventName "experiment_viewed")
        [ sqlNameProperty "experiment",
          sqlNameProperty "variant"
        ]
    ]

plainProperty :: Text -> PropertyType -> Bool -> PropertySpec
plainProperty name propertyType required =
  PropertySpec name propertyType required Nothing

sqlNameProperty :: Text -> PropertySpec
sqlNameProperty name =
  PropertySpec name PTString True (Just SqlNamePattern)
