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
    , proxyScenario
--    , runEmulation
--    , runReal
    ) where

import           Control.Concurrent.MVar           (newEmptyMVar, putMVar, takeMVar)
import           Control.Monad                     (forM_, replicateM_, when)
import           Control.Monad.Catch               (handleAll)
import           Control.Monad.Trans               (liftIO)
import           Data.Binary                       (Binary, Get, Put, get, put)
import           Data.Conduit                      (yield, (=$=))
import qualified Data.Conduit.List                 as CL
import           Data.Conduit.Serialization.Binary (conduitGet, conduitPut)
import           Data.Data                         (Data)
import           Data.MessagePack                  (MessagePack (..))
import           Data.Time.Units                   (convertUnit)
import           Data.Void                         (Void)
import           Data.Word                         (Word16)
import           Formatting                        (sformat, shown, string, (%))
import           GHC.Generics                      (Generic)

import           Control.TimeWarp.Logging          (Severity (Debug), initLogging,
                                                    logDebug, logError, logInfo,
                                                    logWarning, usingLoggerName)
import           Control.TimeWarp.Rpc              (BinaryP (..), Binding (..),
                                                    Listener (..), ListenerH (..),
                                                    Message, MonadTransfer (..),
                                                    NetworkAddress, Port, listen, listenH,
                                                    listenR, localhost, reply, replyRaw,
                                                    runDialog, runTransfer, send, sendH,
                                                    sendR)
import           Control.TimeWarp.Timed            (MonadTimed (wait), Second, after, for,
                                                    fork_, ms, runTimedIO, schedule, sec',
                                                    till, virtualTime, work)

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

guy :: Word16 -> NetworkAddress
guy = (localhost, ) . guysPort

guysPort :: Word16 -> Port
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
        work (till finish) $ ha $
            listen (AtPort $ guysPort 1)
                [ Listener $ \Pong ->
                  do logDebug "Got Pong!"
                     reply $ EpicRequest 14 " men on the dead man's chest"
                ]
        -- guy 1 initiates dialog
        wait (for 100 ms)
        replicateM_ 1 $ do
            send (guy 2) Ping
            logInfo "Sent"

    -- guy 2
    usingLoggerName "guy.2" . runTransfer . runDialog packing . fork_ $ do
        work (till finish) $ ha $
            listen (AtPort $ guysPort 2)
                [ Listener $ \Ping ->
                  do logDebug "Got Ping!"
                     send (guy 1) Pong
                ]
        work (till finish) $ ha $
            listen (AtConnTo $ guy 1) $
                [ Listener $ \EpicRequest{..} ->
                  do logDebug "Got EpicRequest!"
                     wait (for 0.1 sec')
                     logInfo $ sformat (shown%string) (num + 1) msg
                ]
    wait (till finish)
    wait (for 100 ms)
  where
    finish :: Second
    finish = 1

    ha = handleAll $ \e -> do
        t <- virtualTime
        when (t < convertUnit finish) $
            logError $ sformat shown e

    packing :: BinaryP
    packing = BinaryP


-- | Example of `Transfer` usage
transferScenario :: IO ()
transferScenario = runTimedIO $ do
    liftIO $ initLogging ["node"] Debug
    usingLoggerName "node.server" $ runTransfer $
        work (for 500 ms) $ ha $
            let listener req = do
                    logInfo $ sformat ("Got "%shown) req
                    replyRaw $ yield (put $ sformat "Ok!") =$= conduitPut
            in  listenRaw (AtPort 1234) $ conduitGet decoder =$= CL.mapM_ listener

    wait (for 100 ms)

    usingLoggerName "node.client-1" $ runTransfer $
        schedule (after 200 ms) $ ha $ do
            work (for 500 ms) $ ha $
                listenRaw (AtConnTo (localhost, 1234)) $
                    conduitGet get =$= CL.mapM_ logInfo
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
                listenRaw (AtConnTo (localhost, 1234)) $
                    conduitGet get =$= CL.mapM_ logInfo

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

-- * Blind proxy scenario, illustrates work with headers and raw data.
proxyScenario :: IO ()
proxyScenario = runTimedIO $ do
    liftIO $ initLogging ["server", "proxy"] Debug

    lock <- liftIO newEmptyMVar
    let sync act = liftIO (putMVar lock ()) >> act >> liftIO (takeMVar lock)

    -- server

    usingLoggerName "server" . runTransfer . runDialog packing . fork_ $ do
        work (till finish) $
            listenH (AtPort $ 5678)
                [ ListenerH $ \(h, EpicRequest{..}) -> sync . logInfo $
                    sformat ("Got request!: "%shown%" "%shown%"; h = "%shown)
                    num msg (int h)
                ]

    -- proxy
    usingLoggerName "proxy" . runTransfer . runDialog packing . fork_ $ do
        work (till finish) $
            listenR (AtPort 1234)
                [ ListenerH $ \(h, EpicRequest _ _) -> sync . logInfo $
                    sformat ("Proxy! h = "%shown) h
                ]
                $ \(h, raw) -> do
                    when ((int h) < 5) $ do
                        sendR (localhost, 5678) (int h) raw
                        sync $ logInfo $ sformat ("Resend "%shown) h
                    return $ even h


    wait (for 100 ms)

    -- client
    usingLoggerName "client" . runTransfer . runDialog packing . fork_ . ha $ do
        forM_ [1..10] $
            \i -> sendH (localhost, 1234) (int i) $ EpicRequest 34 "lol"

    wait (till 10 ms finish)  -- kinda lol notation
  where
    finish :: Second
    finish = 1

    packing :: BinaryP
    packing = BinaryP

    int :: Int -> Int
    int = id

    ha = handleAll $ logWarning . sformat ("Exception: "%shown)
