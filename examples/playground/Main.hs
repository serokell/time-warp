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
    , rpcScenario
    , transferScenario
--    , runEmulation
--    , runReal
    ) where

import          Control.Monad               (guard, forM_)
import          Control.Monad.Catch         (handleAll)
import          Control.Monad.Trans         (liftIO)
import          Data.Binary                 (Binary, Get, Put, get, put)
import          Data.Data                   (Data)
import          Data.MessagePack            (MessagePack (..))
import          Data.Void                   (Void)
import          GHC.Generics                (Generic)
import          Formatting                  (sformat, (%), shown, string)

import          Control.TimeWarp.Logging    (usingLoggerName, logDebug, logInfo,
                                             initLogging, Severity (Debug), logError,
                                             logWarning)
import          Control.TimeWarp.Timed      (MonadTimed (wait), ms, sec', work,
                                             for, Second, till, fork_, runTimedIO,
                                             after, schedule)
import          Control.TimeWarp.Rpc        (MonadRpc (..), localhost, Listener (..),
                                             Message, Port, NetworkAddress, send,
                                             listen, runTransfer, reply, listenOutbound,
                                             Method (..), mkRequest, runBinaryDialog,
                                             listenOutboundRaw, listenRaw,
                                             sendRaw, replyRaw)

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

$(mkRequest ''Ping ''Pong ''Void)

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
    runTransfer . runBinaryDialog . usingLoggerName "guy.1" . fork_ $ do
        work (till finish) $
            listen (guysPort 1)
                [ Listener $ \Pong -> ha $
                  do logDebug "Got Pong!"
                     reply $ EpicRequest 14 " men on the dead man's chest"
                ]
        -- guy 1 initiates dialog
        wait (for 100 ms)
        send (guy 2) Ping
 
    -- guy 2
    runTransfer . runBinaryDialog . usingLoggerName "guy.2" . fork_ $ do
        work (till finish) $
            listen (guysPort 2)
                [ Listener $ \Ping ->
                  do logDebug "Got Ping!"
                     send (guy 1) Pong
                ] 
        work (till finish) $
            listenOutbound (guy 1) $
                [ Listener $ \EpicRequest{..} -> ha $
                  do logDebug "Got EpicRequest!"
                     wait (for 0.1 sec')
                     logInfo $ sformat (shown%string) (num + 1) msg
                ]

    wait (till finish)
  where
    finish :: Second
    finish = 1

    ha = handleAll $ logError . sformat shown

-- * Simple Rpc scenario
rpcScenario :: (MonadTimed m, MonadRpc m) => m ()
rpcScenario = do
    work (till finish) $
        serve 1234 [ Method $ \Ping -> return Pong
                   ]

    wait (for 100 ms)
    Pong <- call (localhost, 1234) Ping
    return ()
  where
    finish :: Second
    finish = 5

-- | Example of `Transfer` usage
transferScenario :: IO ()
transferScenario = runTimedIO $ do
    liftIO $ initLogging ["node"] Debug
    runTransfer $ usingLoggerName "node.server" $
        work (for 500 ms) $ ha $
            listenRaw 1234 decoder $
            \req -> do
                logInfo $ sformat ("Got "%shown) req
                replyRaw $ put $ sformat "Ok!"

    wait (for 100 ms)

    runTransfer $ usingLoggerName "node.client-1" $
        schedule (after 200 ms) $ ha $ do
            work (for 500 ms) $ ha $
                listenOutboundRaw (localhost, 1234) get logInfo
            forM_ [1..7] $ sendRaw (localhost, 1234) . (put bad >> ) . encoder . Left

    runTransfer $ usingLoggerName "node.client-2" $
        schedule (after 200 ms) $ ha $ do
            forM_ [1..5] $ sendRaw (localhost, 1234) . encoder . Right . (-1, )
            work (for 500 ms) $ ha $
                listenOutboundRaw (localhost, 1234) get logInfo

    wait (for 800 ms)
  where
    ha = handleAll $ logWarning . sformat ("Exception: "%shown)

    decoder :: Get (Either Int (Int, Int))
    decoder = do
        magic <- get
        guard $ magic == magicVal
        get

    encoder :: Either Int (Int, Int) -> Put
    encoder d = put magicVal >> put d

    magicVal :: Int
    magicVal = 234

    bad :: String
    bad = "345"

