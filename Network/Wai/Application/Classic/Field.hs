{-# LANGUAGE OverloadedStrings #-}

module Network.Wai.Application.Classic.Field where

import Control.Applicative
import Control.Arrow (first)
import Control.Monad (mplus)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS hiding (pack)
import Data.ByteString.Char8 as BS (pack)
import qualified Data.Map as Map (toList)
import Data.Maybe
import Data.StaticHash (StaticHash)
import qualified Data.StaticHash as SH
import Network.HTTP.Date
import Network.HTTP.Types
import Network.HTTP.Types.Header
import Network.Wai
import Network.Wai.Application.Classic.Header
import Network.Wai.Application.Classic.Lang
import Network.Wai.Application.Classic.Types
import Network.Wai.Application.Static (defaultMimeTypes, defaultMimeType, MimeType, fromFilePath)
import Network.Wai.Logger.Utils
import System.Posix.Time

----------------------------------------------------------------

languages :: Request -> [ByteString]
languages req = maybe [] parseLang $ lookupRequestField hAcceptLanguage req

ifModifiedSince :: Request -> Maybe HTTPDate
ifModifiedSince = lookupAndParseDate hIfModifiedSince

ifUnmodifiedSince :: Request -> Maybe HTTPDate
ifUnmodifiedSince = lookupAndParseDate hIfUnmodifiedSince

ifRange :: Request -> Maybe HTTPDate
ifRange = lookupAndParseDate hIfRange

lookupAndParseDate :: HeaderName -> Request -> Maybe HTTPDate
lookupAndParseDate key req = lookupRequestField key req >>= parseHTTPDate

----------------------------------------------------------------

textPlainHeader :: ResponseHeaders
textPlainHeader = [(hContentType,"text/plain")]

textHtmlHeader :: ResponseHeaders
textHtmlHeader = [(hContentType,"text/html")]

locationHeader :: ByteString -> ResponseHeaders
locationHeader url = [(hLocation, url)]

addServer :: ClassicAppSpec -> ResponseHeaders -> ResponseHeaders
addServer cspec hdr = (hServer, softwareName cspec) : hdr

-- FIXME: the case where "Via:" already exists
addVia :: ClassicAppSpec -> Request -> ResponseHeaders -> ResponseHeaders
addVia cspec req hdr = (hVia, val) : hdr
  where
    ver = httpVersion req
    showBS = BS.pack . show
    val = BS.concat [
        showBS (httpMajor ver)
      , "."
      , showBS (httpMinor ver)
      , " "
      , serverName req
      , " ("
      , softwareName cspec
      , ")"
      ]

addForwardedFor :: Request -> ResponseHeaders -> ResponseHeaders
addForwardedFor req hdr = (hXForwardedFor, addr) : hdr
  where
    addr = BS.pack . showSockAddr . remoteHost $ req

addLength :: Integer -> ResponseHeaders -> ResponseHeaders
addLength len hdr = (hContentLength, BS.pack (show len)) : hdr

newHeader :: Bool -> ByteString -> HTTPDate -> ResponseHeaders
newHeader ishtml file mtime
  | ishtml    = lastMod : textHtmlHeader
  | otherwise = lastMod : (hContentType, mimeType file) : []
  where
    lastMod = (hLastModified, formatHTTPDate mtime)

mimeType :: ByteString -> MimeType
mimeType file =fromMaybe defaultMimeType . foldr1 mplus . map lok $ targets
  where
    targets = extensions file
    lok x = SH.lookup x defaultMimeTypes'

extensions :: ByteString -> [ByteString]
extensions file = exts
  where
    entire = case BS.breakByte 46 file of -- '.'
        (_,"") -> ""
        (_,x)  -> BS.tail x
    exts = if entire == "" then [] else entire : BS.split 46 file

defaultMimeTypes' :: StaticHash ByteString MimeType
defaultMimeTypes' = SH.fromList $ map (first (BS.pack.fromFilePath)) $ Map.toList defaultMimeTypes

addDate :: ResponseHeaders -> IO ResponseHeaders
addDate hdr = do
    date <- formatHTTPDate . epochTimeToHTTPDate <$> epochTime
    return $ (hDate,date) : hdr
