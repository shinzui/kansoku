-- | Minimal server-derived request data carried by the ingest AuthProtect result.
module Kansoku.Ingest.RequestContext
  ( IngestRequestContext (..),
    emptyRequestContext,
    captureRequestContext,
  )
where

import Data.ByteString qualified as BS
import Data.Text.Encoding qualified as Text
import Kansoku.Prelude
import Network.Wai (Request, requestHeaders)

-- Addresses are intentionally absent. This value is not an event or queue DTO.
data IngestRequestContext = IngestRequestContext
  { userAgent :: !(Maybe Text),
    countryCode :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

emptyRequestContext :: IngestRequestContext
emptyRequestContext = IngestRequestContext Nothing Nothing

captureRequestContext :: (Request -> IO (Maybe Text)) -> Request -> IO IngestRequestContext
captureRequestContext lookupCountry request = do
  countryCode <- lookupCountry request
  let userAgent = do
        bytes <- lookup "User-Agent" (requestHeaders request)
        guard (BS.length bytes <= 2048)
        either (const Nothing) Just (Text.decodeUtf8' bytes)
  pure IngestRequestContext {userAgent, countryCode}
