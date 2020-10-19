{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
module WsAccessToken where

import           Control.Monad.IO.Class         ( MonadIO(liftIO) )
import           Data.Aeson                     ( (.:)
                                                , FromJSON(parseJSON)
                                                , Value(String)
                                                , withObject
                                                )
import qualified Data.ByteString               as BS
import qualified Data.Map                      as Map
import qualified Data.Text                     as T
import           Data.Time.Clock.POSIX          ( POSIXTime
                                                , getPOSIXTime
                                                )
import qualified Data.Vector                   as V
import           Dhall                          ( FromDhall
                                                , Generic
                                                , Text
                                                , Vector
                                                , auto
                                                , input
                                                )
import           Network.HTTP.Req               ( (/:)
                                                , (=:)
                                                , POST(POST)
                                                , ReqBodyUrlEnc(ReqBodyUrlEnc)
                                                , defaultHttpConfig
                                                , https
                                                , jsonResponse
                                                , renderUrl
                                                , req
                                                , responseBody
                                                , runReq, Url, Scheme (Https)
                                                )
import           Prelude                 hiding ( exp )
import           Web.JWT                        ( ClaimsMap(ClaimsMap)
                                                , JWTClaimsSet
                                                  ( aud
                                                  , exp
                                                  , iss
                                                  , sub
                                                  , unregisteredClaims
                                                  )
                                                , Signer(RSAPrivateKey)
                                                , encodeSigned
                                                , numericDate
                                                , readRsaSecret
                                                , stringOrURI
                                                )
import Control.Applicative (liftA3)

data Record = Record
  { keyPath      :: Text
  , issuer       :: Text
  , scopes       :: Vector Text
  , membershipId :: Text
  , audience     :: Text
  }
  deriving (Generic, Show)

instance FromDhall Record


data Config = Config {aws :: Record, wk :: Record}
    deriving (Generic, Show)
instance FromDhall Config

data AccessToken = AccessToken
  { value :: String
  }

instance FromJSON AccessToken where
  parseJSON = withObject "AccessToken" $ \obj -> do
    val <- obj .: "access_token"
    return (AccessToken val)


getSigner :: Record -> IO Signer
getSigner config = do
  content <- (BS.readFile . T.unpack . keyPath) config
  maybe (fail "fail to read secret key")
        (return . RSAPrivateKey)
        (readRsaSecret content)



constructClaimsSet :: Record -> POSIXTime -> JWTClaimsSet
constructClaimsSet config posix = mempty -- mempty returns a default JWTClaimsSet
  { iss                = stringOrURI (issuer config)
  , sub                = stringOrURI (membershipId config)
  , exp                = numericDate posix
  , aud                = Left <$> stringOrURI
                              ((renderUrl . https . audience)  config)
  , unregisteredClaims = ClaimsMap $ Map.fromList
    [("scope", (String . T.intercalate " " . V.toList . scopes) config)]
  }

-- sign :: Record -> IO T.Text
-- sign config = do
--   signer <- getSigner config
--   posix  <- getPOSIXTime
--   return $ encodeSigned signer mempty (constructClaimsSet config posix)

sign :: Record -> IO T.Text
sign config = liftA3 encodeSigned (getSigner config) (return mempty) ( constructClaimsSet config <$> getPOSIXTime)

liftA2 :: (Record -> POSIXTime -> JWTClaimsSet) -> m0 Record -> IO POSIXTime -> IO JWTClaimsSet
liftA2 = error "not implemented"

prepareRequest :: Text -> Url 'Https
prepareRequest aud = foldl (/:) (https host) tails
   where parts = T.splitOn "/" aud
         host = head parts
         tails = tail parts

send :: T.Text -> Record -> IO AccessToken
send assertion config = runReq defaultHttpConfig $ do
  let payload =
        "grant_type"
          =: ("urn:ietf:params:oauth:grant-type:jwt-bearer" :: T.Text)
          <> "assertion"
          =: assertion

  -- One function—full power and flexibility, automatic retrying on timeouts
  -- and such, automatic connection sharing.
  r <- req POST -- method
           (prepareRequest (audience config))
           -- (https "wk-dev.wdesk.org" /: "iam" /: "oauth2" /: "v4.0" /: "token") -- safe by construction URL
           (ReqBodyUrlEnc payload) -- use built-in options or add your own
           jsonResponse -- specify how to interpret response
           mempty -- query params, headers, explicit port number, etc.
  liftIO $ return (responseBody r :: AccessToken)

getAccessToken :: IO ()
getAccessToken = do
  config    <- input auto "./config.dhall"
  assertion <- (sign . wk) config
  token     <- send assertion (wk config)
  (putStrLn . value) token
