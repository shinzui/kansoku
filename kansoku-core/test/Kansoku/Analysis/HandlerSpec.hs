module Kansoku.Analysis.HandlerSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft, isRight)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kansoku.Analysis.Api (Analyses)
import Kansoku.Analysis.Handler
import Kansoku.Analysis.StoreSpec (validInput, withStore)
import Kansoku.Analysis.Types
import Kansoku.Analysis.Validation
import Kansoku.Auth.Handler (authContext)
import Kansoku.Auth.Issue (issueKey)
import Kansoku.Auth.Token (Token (..))
import Kansoku.Auth.Types (CredentialKind (..))
import Kansoku.Event (AccountId (..))
import Kansoku.Prelude
import Kansoku.Server (envelopeFormatters, requestBodyLimits)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (hContentType, statusCode)
import Network.Wai.Handler.Warp qualified as Warp
import Servant (Context (..), serveWithContext)
import Servant.API (NamedRoutes)
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Analysis.Handler" $ do
  it "validates Unicode characters separately from compact UTF-8 bytes" $ do
    forM_ [1, 120] $ \n -> validateAnalysis (validInput & #name .~ Text.replicate n "😀") `shouldSatisfy` isRight
    forM_ [0, 121] $ \n -> validateAnalysis (validInput & #name .~ Text.replicate n "😀") `shouldSatisfy` isLeft
    validateAnalysis (validInput & #name .~ " \n ") `shouldSatisfy` isLeft
    validateAnalysis (validInput & #description ?~ Text.replicate 500 "😀") `shouldSatisfy` isRight
    validateAnalysis (validInput & #description ?~ Text.replicate 501 "😀") `shouldSatisfy` isLeft
    forM_ [validInput & #name .~ "x\0", validInput & #description ?~ "\0"] $ \input -> validateAnalysis input `shouldSatisfy` isLeft
    let doc n = A.object ["x" A..= (Text.replicate 8190 "😀" <> Text.replicate n "a")]
    LBS.length (A.encode (doc 0)) `shouldBe` 32768
    validateAnalysis (validInput & #document .~ doc 0) `shouldSatisfy` isRight
    validateAnalysis (validInput & #document .~ doc 1) `shouldSatisfy` isLeft
    forM_ [A.Null, A.String "text", A.toJSON ([] :: [Int])] $ \document -> validateAnalysis (validInput & #document .~ document) `shouldSatisfy` isLeft
    forM_ [0, -1] $ \version -> validateAnalysis (validInput & #documentVersion .~ version) `shouldSatisfy` isLeft

  it "round-trips authenticated HTTP and rejects malformed fields without changing saved state" $ withStore $ \settings pool -> do
    Token token <- issueKey pool ServiceToken (AccountId "a") "analyses" >>= either (fail . show) (pure . snd)
    Token other <- issueKey pool ServiceToken (AccountId "b") "analyses" >>= either (fail . show) (pure . snd)
    Token write <- issueKey pool WriteKey (AccountId "a") "analyses" >>= either (fail . show) (pure . snd)
    let app = requestBodyLimits 4096 $ serveWithContext (Proxy @(NamedRoutes Analyses)) (envelopeFormatters :. authContext pool) (analysesServer settings 10 pool)
    Warp.testWithApplication (pure app) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      let request credential method path body expected = do
            base <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> path)
            let req = base {HTTP.method = method, HTTP.requestHeaders = [("Authorization", "Bearer " <> Text.encodeUtf8 credential), (hContentType, "application/json")], HTTP.requestBody = HTTP.RequestBodyLBS (maybe "" A.encode body)}
            response <- HTTP.httpLbs req manager
            statusCode (HTTP.responseStatus response) `shouldBe` expected
            when (expected >= 400) $ lookup hContentType (HTTP.responseHeaders response) `shouldBe` Just "application/problem+json"
            either fail pure (A.eitherDecode (HTTP.responseBody response))
      saved <- request token "POST" "/analyses" (Just (toJSON validInput)) 200
      value <- case A.fromJSON saved of A.Success x -> pure (x :: SavedAnalysis); A.Error e -> fail e
      value ^. #document `shouldBe` validInput ^. #document
      let path = "/analyses/" <> show (value ^. #id)
          A.Object fields = toJSON validInput
          replacement = A.Object (KM.insert "revision" (toJSON (Revision 1)) fields)
      request token "GET" path Nothing 200 `shouldReturn` saved
      let boundaryDocument = A.object ["x" A..= Text.replicate 8190 "😀"]
      boundary <- request token "POST" "/analyses" (Just (toJSON (validInput & #document .~ boundaryDocument))) 200
      case A.fromJSON boundary of
        A.Success (large :: SavedAnalysis) -> large ^. #document `shouldBe` boundaryDocument
        A.Error e -> fail e

      forM_ [("GET", Nothing), ("PUT", Just replacement), ("DELETE", Nothing)] $ \(method, body) -> do
        let route = path <> if method == "DELETE" then "?revision=1" else ""
        _ <- request other method route body 404
        _ <- request write method route body 403
        _ <- request "" method route body 401
        pure ()
      forM_ [("kind", A.String "unknown"), ("documentVersion", A.Number 1.5), ("document", A.Null), ("name", A.String "\0")] $ \(field, bad) -> do
        err <- request token "PUT" path (Just (case replacement of A.Object o -> A.Object (KM.insert field bad o); _ -> replacement)) 400
        A.encode err `shouldSatisfy` (not . LBS.null)
        request token "GET" path Nothing 200 `shouldReturn` saved
      forM_ ["name", "kind", "documentVersion", "document", "revision"] $ \field -> do
        let A.Object o = replacement
        _ <- request token "PUT" path (Just (A.Object (KM.delete field o))) 400
        pure ()
      forM_ ["", "?revision=0", "?revision=1.5", "?revision=9223372036854775808"] $ \query -> do
        _ <- request token "DELETE" (path <> query) Nothing 400
        pure ()
      _ <- request token "PUT" path (Just replacement) 200
      _ <- request token "PUT" path (Just replacement) 409
      _ <- request token "DELETE" (path <> "?revision=1") Nothing 409
      _ <- request token "DELETE" (path <> "?revision=2") Nothing 200
      _ <- request token "GET" path Nothing 404
      pure ()
