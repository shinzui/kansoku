{-# LANGUAGE TypeApplications #-}

module Kansoku.Ingest.GeoIPSpec (spec, fixture) where

import Control.Exception (IOException, try)
import Control.Monad (filterM)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.IP (IP, IPRange, toSockAddr)
import Kansoku.Ingest.GeoIP
import Kansoku.Prelude
import Network.Socket (SockAddr)
import Network.Wai (defaultRequest, remoteHost, requestHeaders)
import System.Directory (doesFileExist)
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Ingest.GeoIP" $ do
  it "reads country (not registered country) for IPv4 and IPv6 from an owned MMDB" $ do
    database <- fixture >>= openGeoIP
    countryForAddress database (ip "81.2.69.160") `shouldReturn` Just "GB"
    countryForAddress database (ip "2001:218::") `shouldReturn` Just "JP"
    countryForAddress database (ip "2001:db8::1") `shouldReturn` Nothing

  it "rejects missing and corrupt configured databases at startup" $ do
    missing <- try @IOException (void (openGeoIP "missing-geoip-fixture.mmdb"))
    missing `shouldSatisfy` isLeft
    -- A license text is an owned, real, invalid MMDB input, not a mocked decoder.
    path <- fixture
    corrupt <- try @IOException (void (openGeoIP (take (length path - length ("GeoIP2-Country-Test.mmdb" :: String)) path <> "LICENSE-MIT")))
    corrupt `shouldSatisfy` isLeft
    unsupported <- try @IOException (void (openGeoIP (take (length path - length ("GeoIP2-Country-Test.mmdb" :: String)) path <> "GeoIP2-ISP-Test.mmdb")))
    unsupported `shouldSatisfy` isLeft

  it "requires both database and explicit trusted CIDRs while keeping the default off" $ do
    disabled <- newCountryLookup Nothing []
    disabled defaultRequest `shouldReturn` Nothing
    onlyRanges <- try @IOException (void (newCountryLookup Nothing ["127.0.0.1/32"]))
    onlyRanges `shouldSatisfy` isLeft
    path <- fixture
    onlyDatabase <- try @IOException (void (newCountryLookup (Just path) []))
    onlyDatabase `shouldSatisfy` isLeft
    parseTrustedRanges ["127.0.0.1"] `shouldSatisfy` isLeft
    parseTrustedRanges ["127.0.0.1/33"] `shouldSatisfy` isLeft
    parseTrustedRanges ["::1/129"] `shouldSatisfy` isLeft

  it "ignores spoofed forwarding headers from an untrusted socket peer" $ do
    clientAddress trusted (socket "81.2.69.160") (Just "2001:218::") `shouldBe` Just (ip "81.2.69.160")

  it "walks trusted hops from right to left without trusting a caller-supplied prefix" $ do
    clientAddress trusted (socket "10.0.0.1") (Just "1.2.3.4,81.2.69.160,10.1.1.1") `shouldBe` Just (ip "81.2.69.160")
    clientAddress trusted (socket "::1") (Just "2001:218::,fd00::1") `shouldBe` Just (ip "2001:218::")

  it "fails closed on every malformed chain, missing header, or all-trusted chain" $ do
    mapM_
      (\header -> clientAddress trusted (socket "10.0.0.1") header `shouldBe` Nothing)
      [ Nothing,
        Just "",
        Just "garbage,81.2.69.160",
        Just "81.2.69.160,unknown",
        Just "81.2.69.160,",
        Just "81.2.69.160:443",
        Just "[2001:218::]",
        Just "10.1.1.1,fd00::1",
        Just (BS.intercalate "," (replicate 33 "81.2.69.160")),
        Just (BS.replicate 4097 32),
        Just (BS.pack [255])
      ]

  it "rejects duplicate forwarding headers and returns only a country from a real trusted request" $ do
    path <- fixture
    lookupCountry <- newCountryLookup (Just path) ["127.0.0.1/32"]
    let request = defaultRequest {remoteHost = socket "127.0.0.1", requestHeaders = [("X-Forwarded-For", "81.2.69.160")]}
    lookupCountry request `shouldReturn` Just "GB"
    lookupCountry request {requestHeaders = [("X-Forwarded-For", "81.2.69.160"), ("X-Forwarded-For", "2001:218::")]} `shouldReturn` Nothing
    lookupCountry request {remoteHost = socket "2001:218::"} `shouldReturn` Just "JP"

fixture :: IO FilePath
fixture = do
  candidates <- filterM doesFileExist ["test/fixtures/geoip/GeoIP2-Country-Test.mmdb", "kansoku-core/test/fixtures/geoip/GeoIP2-Country-Test.mmdb"]
  case candidates of
    path : _ -> pure path
    [] -> fail "owned country MMDB fixture missing"

ip :: String -> IP
ip = read

socket :: String -> SockAddr
socket value = toSockAddr (ip value, 0)

trusted :: [IPRange]
trusted = map read ["10.0.0.0/8", "::1/128", "fd00::/8"]
