{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}

module Main
    ( main
    , yohohoScenario
--    , rpcScenario
    , transferScenario
--    , runEmulation
--    , runReal
    ) where

import           Control.Monad                     (forM_, replicateM_, when)
import           Control.Monad.Catch               (handleAll)
import           Control.Monad.Trans               (liftIO)
import           Data.Binary                       (Binary, Get, Put, get, put)
import           Data.Conduit                      (yield, (=$=))
import qualified Data.Conduit.List                 as CL
import           Data.Conduit.Serialization.Binary (conduitGet, conduitPut)
import           Data.Data                         (Data)
import           Data.MessagePack                  (MessagePack (..))
import           Data.Void                         (Void)
import           Formatting                        (sformat, shown, string, (%))
import           GHC.Generics                      (Generic)

import           Control.TimeWarp.Logging          (Severity (Debug), initLogging,
                                                    logDebug, logError, logInfo,
                                                    logWarning, usingLoggerName)
import           Control.TimeWarp.Rpc              (Binding (..), Listener (..), Message,
                                                    MonadTransfer (..), NamedBinaryP (..),
                                                    NetworkAddress, Port, listen,
                                                    localhost, reply, replyRaw, runDialog,
                                                    runTransfer, send)
import           Control.TimeWarp.Timed            (MonadTimed (wait), Second, after, for,
                                                    fork_, ms, runTimedIO, schedule, sec',
                                                    till, work)

main :: IO ()
main = return ()  -- use ghci

{-
runReal :: MsgPackRpc a -> IO a
runReal = runMsgPackRpc

runEmulation :: PureRpc IO a -> IO a
runEmulation scenario = do
    gen <- newStdGen
    runPureRpc delays gen scenario
  where
    delays :: Microsecond
    delays = interval 50 ms
-}

-- * data types

data Ping = Ping
    deriving (Generic, Data, Binary, MessagePack, Message)

data Pong = Pong
    deriving (Generic, Data, Binary, MessagePack, Message)

instance Message Void

data EpicRequest = EpicRequest
    { num :: Int
    , msg :: String
    } deriving (Generic, Data, Binary, MessagePack)

instance Message EpicRequest


-- * scenarios

guy :: Int -> NetworkAddress
guy = (localhost, ) . guysPort

guysPort :: Int -> Port
guysPort = (+10000)

-- Emulates dialog of two guys:
-- 1: Ping
-- 2: Pong
-- 1: EpicRequest ...
-- 2: <prints result>
yohohoScenario :: IO ()
yohohoScenario = runTimedIO $ do
    liftIO $ initLogging ["guy"] Debug

    -- guy 1
    usingLoggerName "guy.1" . runTransfer . runDialog packing . fork_ $ do
        work (till finish) $
            listen (AtPort $ guysPort 1)
                [ Listener $ \Pong -> ha $
                  do logDebug "Got Pong!"
                     reply $ EpicRequest 14 " men on the dead man's chest"
                ]
        -- guy 1 initiates dialog
        wait (for 100 ms)
        replicateM_ 3 $ do
            send (guy 2) Ping
            logInfo "Sent"

    -- guy 2
    usingLoggerName "guy.2" . runTransfer . runDialog packing . fork_ $ do
        work (till finish) $
            listen (AtPort $ guysPort 2)
                [ Listener $ \Ping ->
                  do logDebug "Got Ping!"
                     send (guy 1) Pong
                ]
        work (till finish) $
            listen (AtConnTo $ guy 1) $
                [ Listener $ \EpicRequest{..} -> ha $
                  do logDebug "Got EpicRequest!"
                     wait (for 0.1 sec')
                     logInfo $ sformat (shown%string) (num + 1) msg
                ]
    wait (till finish)
    wait (for 100 ms)
  where
    finish :: Second
    finish = 1

    ha = handleAll $ logError . sformat shown

    packing :: NamedBinaryP
    packing = NamedBinaryP


-- | Example of `Transfer` usage
transferScenario :: IO ()
transferScenario = runTimedIO $ do
    liftIO $ initLogging ["node"] Debug
    usingLoggerName "node.server" $ runTransfer $
        work (for 500 ms) $ ha $
            listenRaw (AtPort 1234) (conduitGet decoder) $
            \req -> do
                logInfo $ sformat ("Got "%shown) req
                replyRaw $ yield (put $ sformat "Ok!") =$= conduitPut

    wait (for 100 ms)

    usingLoggerName "node.client-1" $ runTransfer $
        schedule (after 200 ms) $ ha $ do
            work (for 500 ms) $ ha $
                listenRaw (AtConnTo (localhost, 1234)) (conduitGet get) logInfo
            forM_ ([1..5] :: [Int]) $ \i ->
                sendRaw (localhost, 1234) $ yield i
                                         =$= CL.map Left
                                         =$= CL.map encoder
                                         =$= conduitPut
--                                     =$= awaitForever (\m -> yield "trash" >> yield m)

    usingLoggerName "node.client-2" $ runTransfer $
        schedule (after 200 ms) $ ha $ do
            sendRaw (localhost, 1234) $  CL.sourceList ([1..5] :: [Int])
                                     =$= CL.map (, -1)
                                     =$= CL.map Right
                                     =$= CL.map encoder
                                     =$= conduitPut
            work (for 500 ms) $ ha $
                listenRaw (AtConnTo (localhost, 1234)) (conduitGet get) logInfo

    wait (for 1000 ms)
  where
    ha = handleAll $ logWarning . sformat ("Exception: "%shown)

    decoder :: Get (Either Int (Int, Int))
    decoder = do
        magic <- get
        when (magic /= magicVal) $
            fail "Missed magic constant!"
        get

    encoder :: Either Int (Int, Int) -> Put
    encoder d = put magicVal >> put d

    magicVal :: Int
    magicVal = 234

{-
rpcScenario :: IO ()
rpcScenario = runTimedIO $ do
    liftIO $ initLogging ["server", "cli"] Debug
    usingLoggerName "server" . runTransfer . runBinaryDialog . runRpc $
        work (till finish) $
            serve 1234
                [ Method $ \Ping -> do
                  do logInfo "Got Ping! Wait a sec..."
                     wait (for 1000 ms)
                     logInfo "Replying"
                     return Pong
                ]

    wait (for 100 ms)
    usingLoggerName "client" . runTransfer . runBinaryDialog . runRpc $ do
        Pong <- call (localhost, 1234) Ping
        logInfo "Got Pong!"
    return ()
  where
    finish :: Second
    finish = 5

-}
