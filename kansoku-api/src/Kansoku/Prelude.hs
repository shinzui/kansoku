{-# LANGUAGE PackageImports #-}

-- | The Kansoku project prelude. Every Kansoku module imports this instead of
-- re-importing Text, Generic, the aeson class machinery, lens operators, etc.
module Kansoku.Prelude
  ( module X,
    module Control.Lens,
    eventAesonOptions,
  )
where

import "aeson" Data.Aeson as X
  ( FromJSON,
    Options,
    SumEncoding (..),
    ToJSON,
    camelTo2,
    defaultOptions,
    fromJSON,
    genericParseJSON,
    genericToJSON,
    parseJSON,
    toEncoding,
    toJSON,
  )
import "aeson" Data.Aeson qualified as Aeson
import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad as X (guard, unless, void, when)
import "base" Control.Monad.IO.Class as X (MonadIO, liftIO)
import "base" Data.List.NonEmpty as X (NonEmpty (..))
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing)
import "base" Data.Proxy as X (Proxy (..))
import "base" GHC.Generics as X (Generic)
import "lens" Control.Lens
import "text" Data.Text as X (Text)
import "time" Data.Time as X (UTCTime, getCurrentTime)

-- | Standard Aeson options for Kansoku event/command sum types. Encodes as
-- {"type": "snake_case_tag", "data": {...}} with snake_cased constructor tags.
eventAesonOptions :: Options
eventAesonOptions =
  defaultOptions
    { Aeson.sumEncoding = Aeson.TaggedObject "type" "data",
      Aeson.constructorTagModifier = camelTo2 '_',
      Aeson.tagSingleConstructors = True
    }
