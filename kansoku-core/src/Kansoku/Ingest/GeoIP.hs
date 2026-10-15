{-# LANGUAGE ForeignFunctionInterface #-}

-- | Request addresses live only inside this lookup boundary, never in its result.
module Kansoku.Ingest.GeoIP
  ( GeoIP,
    openGeoIP,
    countryForAddress,
    newCountryLookup,
    parseTrustedRanges,
    clientAddress,
  )
where

import Data.ByteString qualified as BS
import Data.IP (IP (..), IPRange (..), fromSockAddr, isMatchedTo)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.ForeignPtr (FinalizerPtr, ForeignPtr, newForeignPtr, withForeignPtr)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, nullPtr)
import Kansoku.Prelude
import Network.Socket (SockAddr)
import Network.Wai (Request, remoteHost, requestHeaders)
import Text.Read (readMaybe)

newtype GeoIP = GeoIP (ForeignPtr ())

foreign import ccall safe "ks_geo_open" c_open :: CString -> IO (Ptr ())

foreign import ccall unsafe "&ks_geo_close" c_close :: FinalizerPtr ()

foreign import ccall unsafe "ks_geo_country" c_country :: Ptr () -> CString -> CString -> IO CInt

openGeoIP :: FilePath -> IO GeoIP
openGeoIP path = do
  when ('\0' `elem` path) (fail "GeoIP database path contains NUL")
  pointer <- withCString path c_open
  when (pointer == nullPtr) (fail "GeoIP database could not be opened: missing, corrupt or unsupported country/city MMDB")
  GeoIP <$> newForeignPtr c_close pointer

countryForAddress :: GeoIP -> IP -> IO (Maybe Text)
countryForAddress (GeoIP pointer) address =
  withForeignPtr pointer $ \database ->
    withCString (show address) $ \literal ->
      allocaBytes 2 $ \output -> do
        found <- c_country database literal output
        if found == 1 then Just . Text.decodeUtf8 <$> BS.packCStringLen (output, 2) else pure Nothing

parseTrustedRanges :: [Text] -> Either Text [IPRange]
parseTrustedRanges = traverse $ \raw ->
  if Text.count "/" raw /= 1
    then Left "trusted proxies require explicit IPv4/IPv6 CIDRs"
    else maybe (Left "invalid trusted proxy CIDR") Right (readMaybe (Text.unpack (Text.strip raw)))

-- | Untrusted peers are clients; their forwarded header is ignored. Trusted
-- peers must supply a fully valid, bounded chain. The rightmost untrusted hop
-- is the client; no hop to its left is trusted to choose a different address.
clientAddress :: [IPRange] -> SockAddr -> Maybe BS.ByteString -> Maybe IP
clientAddress trusted peer forwarded = do
  (socketAddress, _) <- fromSockAddr peer
  if not (isTrusted socketAddress)
    then Just socketAddress
    else do
      header <- forwarded
      guard (BS.length header <= 4096)
      let pieces = BS.split 44 header
      guard (not (null pieces) && length pieces <= 32)
      addresses <- traverse parseHop pieces
      case dropWhile isTrusted (reverse addresses) of
        address : _ -> Just address
        [] -> Nothing
  where
    parseHop bytes = do
      literal <- either (const Nothing) Just (Text.decodeUtf8' bytes)
      guard (Text.all (`elem` ("0123456789abcdefABCDEF:. \t" :: String)) literal)
      readMaybe (Text.unpack (Text.strip literal))
    isTrusted address = any (matches address) trusted
    matches (IPv4 address) (IPv4Range range) = isMatchedTo address range
    matches (IPv6 address) (IPv6Range range) = isMatchedTo address range
    matches _ _ = False

newCountryLookup :: Maybe FilePath -> [Text] -> IO (Request -> IO (Maybe Text))
newCountryLookup Nothing [] = pure (const (pure Nothing))
newCountryLookup (Just path) ranges@(_ : _) = do
  trusted <- either (fail . Text.unpack) pure (parseTrustedRanges ranges)
  database <- openGeoIP path
  pure $ \request ->
    let forwarded = case [value | (name, value) <- requestHeaders request, name == "X-Forwarded-For"] of
          [value] -> Just value
          _ -> Nothing
     in maybe (pure Nothing) (countryForAddress database) (clientAddress trusted (remoteHost request) forwarded)
newCountryLookup _ _ = fail "GeoIP requires both KANSOKU_INGEST_GEOIP_DB and nonempty KANSOKU_INGEST_TRUSTED_PROXY_CIDRS"
