{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}

module Main
    ( main
    , yohohoScenario
--    , rpcScenario
    , transferScenario
    , proxyScenario
    , slowpokeScenario
    , closingServerScenario
--    , runEmulation
--    , runReal
    ) where

import           Control.Concurrent.MVar           (newEmptyMVar, putMVar, takeMVar)
import           Control.Concurrent.STM.TVar       (modifyTVar, newTVar, readTVar)
import           Control.Monad                     (forM_, replicateM_, when)
import           Control.Monad.STM                 (atomically)
import           Control.Monad.Trans               (MonadIO (liftIO))

import           Data.Binary                       (Binary, Get, Put, get, put)
import           Data.Conduit                      (yield, (=$=))
import qualified Data.Conduit.List                 as CL
import           Data.Conduit.Serialization.Binary (conduitGet, conduitPut)
import           Data.Data                         (Data)
import           Data.MessagePack                  (MessagePack (..))
import           Data.Void                         (Void)
import           Data.Word                         (Word16)
import           Formatting                        (sformat, shown, string, (%))
import           GHC.Generics                      (Generic)

import           System.Wlog                       (LoggerName, Severity (Debug),
                                                    initLogging, logDebug, logError,
                                                    logInfo, usingLoggerName)

import           Control.TimeWarp.Rpc              (BinaryP (..), Binding (..),
                                                    Listener (..), ListenerH (..),
                                                    Message, MonadTransfer (..),
                                                    NetworkAddress, Port, listen, listenH,
                                                    listenR, localhost, reply, replyRaw,
                                                    runDialog, runTransfer, runTransferS,
                                                    send, sendH, sendR, transferSettings,
                                                    _reconnectPolicy)
import           Control.TimeWarp.Timed            (MonadTimed (wait), Second, after, for,
                                                    fork_, interval, ms, runTimedIO,
                                                    schedule, sec, sec', till)

-- use ghci; this is only for logger debugging
main :: IO ()
main = return ()

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

-- | Examples management info.
narrator :: LoggerName
narrator = "*"

-- Emulates dialog of two guys, maybe several times, in parallel:
-- 1: Ping
-- 2: Pong
-- 1: EpicRequest ...
-- 2: <prints result>
yohohoScenario :: IO ()
yohohoScenario = runTimedIO $ do
    initLogging Debug
    (saveWorker, killWorkers) <- newNode narrator workersManager

    -- guy 1
    newNode "guy.1" . fork_ $ do
        saveWorker $ listen (AtPort $ guysPort 1)
            [ Listener $ \Pong ->
              do logDebug "Got Pong!"
                 reply $ EpicRequest 14 " men on the dead man's chest"
            ]
        -- guy 1 initiates dialog
        wait (for 100 ms)
        replicateM_ 2 $ do
            send (guy 2) Ping
            logInfo "Sent"


    -- guy 2
    newNode "guy.2" . fork_ $ do
        saveWorker $ listen (AtPort $ guysPort 2)
            [ Listener $ \Ping ->
              do logDebug "Got Ping!"
                 send (guy 1) Pong
            ]
        saveWorker $ listen (AtConnTo $ guy 1)
            [ Listener $ \EpicRequest{..} ->
              do logDebug "Got EpicRequest!"
                 wait (for 0.1 sec')
                 logInfo $ sformat (shown%string) (num + 1) msg
            ]

    wait (till finish)
    newNode narrator killWorkers
    wait (for 100 ms)
  where
    finish :: Second
    finish = 5

    newNode name = usingLoggerName name . runTransfer . runDialog BinaryP

    guy :: Word16 -> NetworkAddress
    guy = (localhost, ) . guysPort

    guysPort :: Word16 -> Port
    guysPort = (+10000)


-- | Example of `Transfer` usage
transferScenario :: IO ()
transferScenario = runTimedIO $ do
    initLogging Debug
    (saveWorker, killWorkers) <- newNode narrator workersManager

    newNode "node.server" $
        let listener req = do
                logInfo $ sformat ("Got "%shown) req
                replyRaw $ yield (put $ sformat "Ok!") =$= conduitPut
        in  saveWorker $ listenRaw (AtPort 1234) $
                conduitGet decoder =$= CL.mapM_ listener

    wait (for 100 ms)

    newNode "node.client-1" $
        schedule (after 200 ms) $ do
            saveWorker $ listenRaw (AtConnTo (localhost, 1234)) $
                    conduitGet get =$= CL.mapM_ logInfo
            forM_ ([1..5] :: [Int]) $ \i ->
                sendRaw (localhost, 1234) $ yield i
                                         =$= CL.map Left
                                         =$= CL.map encoder
                                         =$= conduitPut
--                                     =$= awaitForever (\m -> yield "trash" >> yield m)

    newNode "node.client-2" $
        schedule (after 200 ms) $ do
            sendRaw (localhost, 1234) $  CL.sourceList ([1..5] :: [Int])
                                     =$= CL.map (, -1)
                                     =$= CL.map Right
                                     =$= CL.map encoder
                                     =$= conduitPut
            saveWorker $ listenRaw (AtConnTo (localhost, 1234)) $
                conduitGet get =$= CL.mapM_ logInfo

    wait (for 1000 ms)
    newNode narrator killWorkers
    wait (for 100 ms)
  where
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

    newNode name = usingLoggerName name . runTransfer

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
    liftIO $ initLogging Debug
    (saveWorker, killWorkers) <- newNode narrator workersManager

    lock <- liftIO newEmptyMVar
    let sync act = liftIO (putMVar lock ()) >> act >> liftIO (takeMVar lock)

    -- server
    newNode "server" . fork_ $
        saveWorker $ listenH (AtPort 5678)
            [ ListenerH $ \(h, EpicRequest{..}) -> sync . logInfo $
                sformat ("Got request!: "%shown%" "%shown%"; h = "%shown)
                num msg (int h)
            ]

    -- proxy
    newNode "proxy" . fork_ $
        saveWorker $ listenR (AtPort 1234)
            [ ListenerH $ \(h, EpicRequest _ _) -> sync . logInfo $
                sformat ("Proxy! h = "%shown) h
            ]
            $ \(h, raw) -> do
                when (int h < 5) $ do
                    sendR (localhost, 5678) (int h) raw
                    sync $ logInfo $ sformat ("Resend "%shown) h
                return $ even h


    wait (for 100 ms)

    -- client
    newNode "client" . fork_  $
        forM_ [1..10] $
            \i -> sendH (localhost, 1234) (int i) $ EpicRequest 34 "lol"

    wait (till finish)
    newNode narrator killWorkers
    wait (for 100 ms)
  where
    finish :: Second
    finish = 1

    newNode name = usingLoggerName name . runTransfer . runDialog BinaryP

    int :: Int -> Int
    int = id


-- | Slowpoke server scenario
slowpokeScenario :: IO ()
slowpokeScenario = runTimedIO $ do
    initLogging Debug
    (saveWorker, killWorkers) <- newNode narrator workersManager

    newNode "server" . fork_ $ do
        wait (for 3 sec)
        saveWorker $ listen (AtPort 1234)
            [ Listener $ \Ping -> logDebug "Got Ping!"
            ]

    newNode "client" . fork_ $ do
        wait (for 100 ms)
        replicateM_ 3 $ send (localhost, 1234) Ping

    wait (till finish)
    newNode narrator killWorkers
    wait (for 100 ms)
  where
    finish :: Second
    finish = 5

    newNode name = usingLoggerName name . runTransferS settings . runDialog BinaryP

    settings = transferSettings
        { _reconnectPolicy = \failsInRow -> return $
            if failsInRow < 5 then Just (interval 1 sec) else Nothing
        }

closingServerScenario :: IO ()
closingServerScenario = runTimedIO $ do
    initLogging Debug
    (saveWorker, killWorkers) <- newNode narrator workersManager

    newNode "server" . fork_ $
        saveWorker $ listen (AtPort 1234) []

    wait (for 100 ms)

    newNode "client" $
        replicateM_ 3 $ do
            closer <- listen (AtConnTo (localhost, 1234)) []
            wait (for 500 ms)
            closer

    wait (till finish)
    newNode narrator killWorkers
    wait (for 100 ms)
  where
    finish :: Second
    finish = 3

    newNode name = usingLoggerName name . runTransfer . runDialog BinaryP


workersManager :: MonadIO m => m (m (m ()) -> m (), m ())
workersManager = do
    t <- liftIO . atomically $ newTVar []
    let saveWorker action = do
            closer <- action
            liftIO . atomically $ modifyTVar t (closer:)
        killWorkers = sequence_ =<< liftIO (atomically $ readTVar t)

    return (saveWorker, killWorkers)
