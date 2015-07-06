
{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}

-- | A bimap server is basically a server that stores a one-to-one correspondence between
--   two sets of values. You can think of it as a table with two columns, where each column
--   has elements of the same type. You can lookup the table and update it using JSON based
--   HTTP requests.
--
--   This is how you run the server:
--
-- > bimapServer (Proxy :: Proxy Int) -- This proxy specifies the type of the values in the left column
-- >             (Proxy :: Proxy String) -- This proxy specifies the type of the values in the right column
-- >              5000 -- Server will be running in port 5000
-- >              60 -- This is the number of seconds between saves
--
--   In this example, the server will save in the file @"saved.bimap"@ the table every 60 seconds.
--   Keep in mind that 'bimapServer' will install a handle for SIGTERM signals, meaning that a 'kill' signal
--   will be catched by the process, triggering a save of the table. After saving the table, the server will
--   stop running. However, the port that the server was using may still not be available until the program
--   using 'bimapServer' is closed.
--
--   The interface of the server is as follows:
--
--   * [GET] @/list@: Returns the list of rows in the table. The format is @[[a1,b1],...,[aN,bN]]@. You can use
--                    the aeson's encoding of the type @[(a,b)]@ for decoding it.
--
--   * [GET] @/left-lookup@: Lookup an element in the table by searching in the left column. It returns the element
--                           in the right column (if any) in JSON format as described by the 'ToJSON' instance. The
--                           element to lookup is specified using its JSON encoded form as the body of the HTTP request.
--   * [GET] @/right-lookup@: Just as @/left-lookup@, except that using the right column for searching, and returning
--                            the element in the left column (if any).
--
--   * [POST] @/insert@: Insert a pair of values in the table, replacing any occurences. The pair is sent in the body
--                       of the HTTP request, in JSON format, using the aeson's encoding of pairs (tuples of size 2).
--
--   * [DELETE] @/left-delete@: Delete a row by searching in the left column. The value to look for in the left column
--                              is passed JSON-encoded as the body of the HTTP request.
--
--   * [DELETE] @/right-delete@: Just as @/left-delete@, but searching in the right column.
--
module Data.Bimap.Server (
    bimapServer
  , Proxy (..)
  ) where

import Data.Bimap (Bimap)
import qualified Data.Bimap as BM
import Data.Proxy
import Network.Wai.Handler.Warp
  ( runSettings
  , defaultSettings
  , setPort
  , setServerName
    )
import Network.Wai
  ( responseLBS
  , strictRequestBody
  , pathInfo
  , requestMethod
    )
import Network.HTTP.Types
  ( ok200
  , badRequest400
  , notFound404
    )
import Control.Concurrent.MVar
import Data.Aeson
  ( eitherDecode
  , encode
  , ToJSON
  , FromJSON
    )
import Data.Binary (Binary, encodeFile, decodeFile)
import Data.String (fromString)
import Control.Concurrent (forkIO, threadDelay, killThread)
import Control.Monad (when, forever)
import System.Posix.Signals
  ( installHandler
  , Handler (CatchOnce)
  , softwareTermination
    )
import System.Directory (doesFileExist)

-- | Function to start a bimap server. The 'Binary' instances are used
--   for saving the table to file. 'FromJSON' and 'ToJSON' instances are
--   used for the HTTP interface. The 'Ord' instances are used to implement
--   fast lookups.
bimapServer :: forall a b .
               ( Binary   a, Binary b
               , FromJSON a, FromJSON b
               , ToJSON   a, ToJSON b
               , Ord      a, Ord b
                 )
            => Proxy a -- ^ Type of left keys
            -> Proxy b -- ^ Type of right keys
            -> Int -- ^ Port to run the server
            -> Int -- ^ Number of seconds between saves
            -> IO ()
bimapServer _ _ p saveTime = do
  let settings = setPort p
               . setServerName "bimap-server"
  -- Bimap variable
  v <- newMVar (BM.empty :: Bimap a b)
  -- Semaphore variable
  sv <- newMVar ()
  -- Final handle variable
  fv <- newEmptyMVar
  -- Load file
  let saveFile = "saved.bimap"
  exst <- doesFileExist saveFile
  when exst $ modifyMVar_ v $ const $ BM.fromList <$> decodeFile saveFile
  -- Periodic file saving
  _ <- forkIO $ forever $ do
         threadDelay $ saveTime * 1000 * 1000
         takeMVar sv
         readMVar v >>= encodeFile saveFile . BM.toList
         putMVar sv ()
  --
  let app req respr =
         -- Response builder
         case (requestMethod req, pathInfo req) of
           -- Left lookup
           ("GET",["left-lookup"]) -> do
             ek <- eitherDecode <$> strictRequestBody req
             case ek of
               Left err -> respr $ responseLBS badRequest400 [] $ fromString $ "Malformed or missing JSON: " ++ err ++ "\n"
               Right k -> do
                 bm <- readMVar v
                 respr $ case BM.lookup k bm of
                   Just x -> responseLBS ok200 [] $ encode x
                   _ -> responseLBS notFound404 [] "Requested left key not found.\n"
           -- Right lookup
           ("GET",["right-lookup"]) -> do
             ek <- eitherDecode <$> strictRequestBody req
             case ek of
               Left err -> respr $ responseLBS badRequest400 [] $ fromString $ "Malformed or missing JSON: " ++ err ++ "\n"
               Right k -> do
                 bm <- readMVar v
                 respr $ case BM.lookupR k bm of
                   Just x -> responseLBS ok200 [] $ encode x
                   _ -> responseLBS notFound404 [] "Requested right key not found.\n"
           -- Insert
           ("POST",["insert"]) -> do
             ep <- eitherDecode <$> strictRequestBody req
             case ep of
               Left err -> respr $ responseLBS badRequest400 [] $ fromString $ "Malformed input: " ++ err ++ "\n"
               Right (l,r) -> do
                 modifyMVar_ v $ return . BM.insert l r
                 respr $ responseLBS ok200 [] "Row inserted.\n"
           -- List
           ("GET",["list"]) -> (>>=respr) $ responseLBS ok200 [] . encode . BM.toList <$> readMVar v
           -- Left delete
           ("DELETE",["left-delete"]) -> do
             ek <- eitherDecode <$> strictRequestBody req
             case ek of
               Left err -> respr $ responseLBS badRequest400 [] $ fromString $ "Malformed or missing JSON: " ++ err ++ "\n"
               Right k -> do
                 modifyMVar_ v $ return . BM.delete k
                 respr $ responseLBS ok200 [] "Row deleted.\n"
           -- Right delete
           ("DELETE",["right-delete"]) -> do
             ek <- eitherDecode <$> strictRequestBody req
             case ek of
               Left err -> respr $ responseLBS badRequest400 [] $ fromString $ "Malformed or missing JSON: " ++ err ++ "\n"
               Right k -> do
                 modifyMVar_ v $ return . BM.deleteR k
                 respr $ responseLBS ok200 [] "Row deleted.\n"
           -- 404
           _ -> respr $ responseLBS notFound404 [] "The requested route does not exist, or you are using the wrong method.\n"
         --
  th <- forkIO $ runSettings (settings defaultSettings) app
  _ <- installHandler softwareTermination (CatchOnce $ putMVar fv ()) Nothing
  takeMVar fv
  takeMVar sv -- Semaphore is set permanently in red
  readMVar v >>= encodeFile saveFile . BM.toList
  killThread th -- Kill server
