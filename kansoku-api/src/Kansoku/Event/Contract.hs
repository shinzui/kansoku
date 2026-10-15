-- | Stable, serializable publication of the in-source event registry.
module Kansoku.Event.Contract
  ( ContractProperty (..),
    EventVersions (..),
    SchemaCatalog (..),
    VersionedEventSchema (..),
    propertyTypeText,
    schemaCatalog,
  )
where

import Data.Aeson.Types (Options (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Kansoku.Event.Registry
import Kansoku.Event.Types (EventName (..), allowedIdentifierKindNames)
import Kansoku.Prelude

data ContractProperty = ContractProperty
  { name :: !Text,
    propertyType :: !Text,
    required :: !Bool,
    validationPattern :: !(Maybe Text),
    description :: !(Maybe Text),
    minimum :: !(Maybe Int),
    minLength :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

data VersionedEventSchema = VersionedEventSchema
  { version :: !Int,
    note :: !Text,
    properties :: ![ContractProperty]
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

newtype EventVersions = EventVersions
  { versions :: NonEmpty VersionedEventSchema
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data SchemaCatalog = SchemaCatalog
  { catalogVersion :: !Int,
    service :: !Text,
    identifierKinds :: ![Text],
    events :: !(Map Text EventVersions)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

contractPropertyOptions :: Options
contractPropertyOptions =
  defaultOptions
    { omitNothingFields = True,
      fieldLabelModifier = \case
        "propertyType" -> "type"
        "validationPattern" -> "pattern"
        field -> field
    }

instance ToJSON ContractProperty where
  toJSON = genericToJSON contractPropertyOptions

instance FromJSON ContractProperty where
  parseJSON = genericParseJSON contractPropertyOptions

propertyTypeText :: PropertyType -> Text
propertyTypeText = \case
  PTString -> "string"
  PTNumber -> "number"
  PTBool -> "bool"
  PTObject -> "object"
  PTArray -> "array"
  PTAny -> "any"

schemaCatalog :: EventRegistry -> SchemaCatalog
schemaCatalog (EventRegistry registry) =
  SchemaCatalog
    { catalogVersion = 3,
      service = "kansoku",
      identifierKinds = allowedIdentifierKindNames,
      events =
        Map.fromList
          [ (unEventName eventName, EventVersions (toContractSchema <$> schemas))
          | (eventName, schemas) <- Map.toAscList registry
          ]
    }

toContractSchema :: EventSchema -> VersionedEventSchema
toContractSchema EventSchema {version, note, properties} =
  VersionedEventSchema
    { version = version,
      note = note,
      properties = toContractProperty <$> properties
    }

toContractProperty :: PropertySpec -> ContractProperty
toContractProperty PropertySpec {name, propertyType, required, validationPattern, description} =
  ContractProperty
    { name = name,
      propertyType = propertyTypeText propertyType,
      required = required,
      validationPattern = case validationPattern of Just SqlNamePattern -> Just (propertyPatternText SqlNamePattern); _ -> Nothing,
      description = description,
      minimum = case validationPattern of Just NonNegativeNumberPattern -> Just 0; _ -> Nothing,
      minLength = case validationPattern of Just NonEmptyStringPattern -> Just 1; _ -> Nothing
    }
