-- | In-memory event schema registry for extra validation of known event names.
module Kansoku.Event.Registry
  ( EventRegistry (..),
    EventSchema (..),
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

data PropertySpec = PropertySpec
  { propName :: !Text,
    propType :: !PropertyType,
    propRequired :: !Bool
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
        [PropertySpec "url" PTString True],
      EventSchema
        (EventName "session_start")
        [PropertySpec "sessionId" PTString True],
      EventSchema
        (EventName "identify")
        [],
      EventSchema
        (EventName "user_registered")
        [PropertySpec "userId" PTString True],
      EventSchema
        (EventName "subscription_started")
        [ PropertySpec "plan" PTString True,
          PropertySpec "amount" PTNumber False
        ],
      EventSchema
        (EventName "payment_completed")
        [ PropertySpec "amount" PTNumber True,
          PropertySpec "plan" PTString False
        ],
      EventSchema
        (EventName "feature_used")
        [PropertySpec "feature" PTString True]
    ]
