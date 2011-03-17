{-# LANGUAGE OverloadedStrings #-}

-- % mighty mighty.conf mighty.route
-- % runghc -i.. Test.hs

module Test where

import qualified Data.ByteString.Lazy.Char8 as BL
import Network.HTTP.Enumerator
import qualified Network.Wai as W
import Network.Wai.Application.Date
import Network.Wai.Application.Lang
import Network.Wai.Application.Range
import Network.Wai.Application.Header
import Test.Framework (defaultMain, testGroup, Test)
import Test.Framework.Providers.HUnit
import Test.HUnit hiding (Test)
import Data.Enumerator (run_)

tests :: [Test]
tests = [
    testGroup "default" [
         testCase "lang" test_lang
       , testCase "date" test_date
       , testCase "range" test_range
       ]
  , testGroup "mighty" [
         testCase "post" test_post
       , testCase "get" test_get
       , testCase "get2" test_get2
       , testCase "get_ja" test_get_ja
       , testCase "get_modified" test_get_ja
       , testCase "test_get_modified" test_get_modified
       , testCase "head" test_head
       , testCase "head2" test_head2
       , testCase "head_ja" test_head_ja
       , testCase "head_modified" test_head_ja
       , testCase "test_head_modified" test_head_modified
       ]
  ]

----------------------------------------------------------------

test_lang :: Assertion
test_lang = do
    let res = parseLang "en-gb;q=0.8, en;q=0.7, da"
    res @?= ans
  where
    ans = ["da","en-gb","en"]

----------------------------------------------------------------

test_date :: Assertion
test_date = do
    let Just x = parseDate date
        res = utcToDate x
    res @?= date
  where
    date = "Tue, 15 Nov 1994 08:12:31 GMT"

----------------------------------------------------------------

test_range :: Assertion
test_range = do
    let res1 = skipAndSize range1 size
        res2 = skipAndSize range2 size
        res3 = skipAndSize range3 size
        res4 = skipAndSize range4 size
    res1 @?= ans1
    res2 @?= ans2
    res3 @?= ans3
    res4 @?= ans4
  where
    size = 10000
    range1 = "bytes=0-399"
    range2 = "bytes=500-799"
    range3 = "bytes=-500"
    range4 = "bytes=9500-"
    ans1 = Just (0,400)
    ans2 = Just (500,300)
    ans3 = Just (9500,500)
    ans4 = Just (9500,500)

----------------------------------------------------------------

test_post :: Assertion
test_post = do
    rsp <- sendPOST url "foo bar.\nbaz!\n"
    ans <- BL.readFile "data/post"
    rsp @?= ans
  where
    url = "http://localhost:8080/cgi-bin/echo-env/pathinfo?query"

sendPOST :: String -> BL.ByteString -> IO BL.ByteString
sendPOST url body = do
    req' <- parseUrl url
    let req = req' {
            method = "POST"
          , requestBody = body
          }
    Response sc _ b <- httpLbs req
    if 200 <= sc && sc < 300
        then return b
        else error "sendPOST"

----------------------------------------------------------------

test_get :: Assertion
test_get = do
    rsp <- simpleHttp url
    ans <- BL.readFile "html/index.html"
    rsp @?= ans
  where
    url = "http://localhost:8080/"

----------------------------------------------------------------

test_get2 :: Assertion
test_get2 = do
    Response rc _ _ <- parseUrl url >>= httpLbs
    rc @?= notfound
  where
    url = "http://localhost:8080/dummy"
    notfound = 404

----------------------------------------------------------------

test_get_ja :: Assertion
test_get_ja = do
    Response _ _ bdy <- sendGET url [("Accept-Language", "ja, en;q=0.7")]
    ans <- BL.readFile "html/ja/index.html.ja"
    bdy @?= ans
  where
    url = "http://localhost:8080/ja/"

----------------------------------------------------------------

test_get_modified :: Assertion
test_get_modified = do
    Response _ hdr _ <- sendGET url []
    let Just lm = lookupField fkLastModified hdr
    Response sc _ _ <- sendGET url [("If-Modified-Since", lm)]
    sc @?= 304
  where
    url = "http://localhost:8080/"

----------------------------------------------------------------

sendGET :: String -> Headers -> IO Response
sendGET url hdr = do
    req' <- parseUrl url
    let req = req' { requestHeaders = hdr }
    httpLbs req

----------------------------------------------------------------

test_head :: Assertion
test_head = do
    Response rc _ _ <- sendHEAD url []
    rc @?= ok
  where
    url = "http://localhost:8080/"
    ok = 200

----------------------------------------------------------------

test_head2 :: Assertion
test_head2 = do
    Response rc _ _ <- sendHEAD url []
    rc @?= notfound
  where
    url = "http://localhost:8080/dummy"
    notfound = 404

----------------------------------------------------------------

test_head_ja :: Assertion
test_head_ja = do
    Response rc _ _ <- sendHEAD url [("Accept-Language", "ja, en;q=0.7")]
    rc @?= ok
  where
    url = "http://localhost:8080/ja/"
    ok = 200

----------------------------------------------------------------

test_head_modified :: Assertion
test_head_modified = do
    Response _ hdr _ <- sendHEAD url []
    let Just lm = lookupField fkLastModified hdr
    Response sc _ _ <- sendHEAD url [("If-Modified-Since", lm)]
    sc @?= 304
  where
    url = "http://localhost:8080/"

----------------------------------------------------------------

sendHEAD :: String -> Headers -> IO Response
sendHEAD url hdr = do
    req' <- parseUrl url
    let req = req' {
            requestHeaders = hdr
          , method = "HEAD"
          }
    run_ $ http req headIter
  where
    headIter (W.Status sc _) hs = return $ Response sc hs ""

----------------------------------------------------------------

main :: Assertion
main = defaultMain tests
