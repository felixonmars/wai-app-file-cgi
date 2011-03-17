{-# LANGUAGE OverloadedStrings #-}

module Network.Wai.Application.CGI (cgiApp, CgiRoute(..), AppSpec(..)) where

import Blaze.ByteString.Builder.ByteString
import Control.Applicative
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.Char
import Data.Enumerator (Iteratee,run_,($$))
import qualified Data.Enumerator as E (map)
import qualified Data.Enumerator.Binary as EB
import qualified Data.Enumerator.List as EL
import Data.List (isPrefixOf)
import Data.Maybe
import Network.Socket (getNameInfo, SockAddr, NameInfoFlag(..))
import Network.Wai
import Network.Wai.Application.Utils
import System.FilePath
import System.IO
import System.Process

import Network.Wai.Application.EnumLine as ENL
import Network.Wai.Application.Types
import Network.Wai.Application.Header

----------------------------------------------------------------

type ENVVARS = [(String,String)]
type NumericAddress = String

gatewayInterface :: String
gatewayInterface = "CGI/1.1"

----------------------------------------------------------------

cgiApp :: AppSpec -> CgiRoute -> Application
cgiApp spec cgii req = case method of
    "GET"  -> cgiApp' False spec cgii req
    "POST" -> cgiApp' True  spec cgii req
    _      -> return $ responseLBS statusNotAllowed textPlain "Method not allowed"
  where
    method = requestMethod req

cgiApp' :: Bool -> AppSpec -> CgiRoute -> Application
cgiApp' body spec cgii req = do
    naddr <- liftIO . getPeerAddr . remoteHost $ req
    (Just whdl,Just rhdl,_,_) <- liftIO . createProcess . proSpec $ naddr
    liftIO $ do
        hSetEncoding rhdl latin1
        hSetEncoding whdl latin1
    when body $ EL.consume >>= liftIO . mapM_ (BS.hPutStr whdl)
    liftIO . hClose $ whdl
    (return . ResponseEnumerator) (\build ->
        run_ $ EB.enumHandle 4096 rhdl $$
        ((>>= check) <$> parseHeader) >>= maybe (responseNG build)
                                                (responseOK build))
  where
    proSpec naddr = CreateProcess {
        cmdspec = RawCommand prog []
      , cwd = Nothing
      , env = Just (makeEnv req naddr scriptName pathinfo (softwareName spec))
      , std_in = CreatePipe
      , std_out = CreatePipe
      , std_err = Inherit
      , close_fds = True
      }
    (prog, scriptName, pathinfo) = pathinfoToCGI (cgiSrc cgii)
                                                 (cgiDst cgii)
                                                 (pathInfo req)
    toBuilder = E.map fromByteString
    emptyBody = EB.isolate 0
    responseOK build (status,hs)  = toBuilder =$ build status hs
    responseNG build = emptyBody =$ toBuilder =$ build status500 []
    check hs = lookupField fkContentType hs >> case lookupField "status" hs of
        Nothing -> Just (status200, hs)
        Just l  -> toStatus l >>= \s -> Just (s,hs')
      where
        hs' = filter (\(k,_) -> ciLowerCase k /= "status") hs
    toStatus s = BS.readInt s >>= \x -> Just (Status (fst x) s)

----------------------------------------------------------------

makeEnv :: Request -> NumericAddress -> String -> String -> String -> ENVVARS
makeEnv req naddr scriptName pathinfo sname = addLength . addType . addCookie $ baseEnv
  where
    baseEnv = [
        ("GATEWAY_INTERFACE", gatewayInterface)
      , ("SCRIPT_NAME",       scriptName)
      , ("REQUEST_METHOD",    BS.unpack . requestMethod $ req)
      , ("SERVER_NAME",       BS.unpack . serverName $ req)
      , ("SERVER_PORT",       show . serverPort $ req)
      , ("REMOTE_ADDR",       naddr)
      , ("SERVER_PROTOCOL",   "HTTP/" ++ (BS.unpack . httpVersion $ req))
      , ("SERVER_SOFTWARE",   sname)
      , ("PATH_INFO",         pathinfo)
      , ("QUERY_STRING",      BS.unpack . queryString $ req)
      ]
    headers = requestHeaders req
    addLength = addEnv "CONTENT_LENGTH" $ lookupField fkContentLength headers
    addType   = addEnv "CONTENT_TYPE" $ lookupField fkContentType headers
    addCookie = addEnv "HTTP_COOKIE" $ lookupField fkCookie headers

addEnv :: String -> Maybe ByteString -> ENVVARS -> ENVVARS
addEnv _   Nothing    envs = envs
addEnv key (Just val) envs = (key,BS.unpack val) : envs

----------------------------------------------------------------

getPeerAddr :: SockAddr -> IO NumericAddress
getPeerAddr sa = strip . fromJust . fst <$> getInfo sa
  where
    getInfo = getNameInfo [NI_NUMERICHOST, NI_NUMERICSERV] True True
    strip x
      | "::ffff:" `isPrefixOf` x = drop 7 x
      | otherwise                = x

----------------------------------------------------------------

parseHeader :: Iteratee ByteString IO (Maybe RequestHeaders)
parseHeader = takeHeader >>= maybe (return Nothing)
                                   (return . Just . map parseField)
  where
    parseField bs = (CIByteString key skey, val)
      where
        (key,val) = case BS.break (==':') bs of
            kv@(_,"") -> kv
            (k,v) -> let v' = BS.dropWhile (==' ') $ BS.tail v in (k,v')
        skey = BS.map toLower key

takeHeader :: Iteratee ByteString IO (Maybe [ByteString])
takeHeader = ENL.head >>= maybe (return Nothing) $. \l ->
    if l == ""
       then return (Just [])
       else takeHeader >>= maybe (return Nothing) (return . Just . (l:))

pathinfoToCGI :: ByteString -> FilePath -> ByteString -> (FilePath, String, String)
pathinfoToCGI src dst path = (prog, scriptName, pathinfo)
  where
    src' = BS.unpack src
    path' = drop (BS.length src) $ BS.unpack path
    (prog',pathinfo) = break (== '/') path'
    prog = dst </> prog'
    scriptName = src' </> prog'
