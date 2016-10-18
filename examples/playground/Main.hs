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
--    , runEmulation
--    , runReal
    ) where

import          Control.Monad.Catch         (handleAll)
import          Control.Monad.Trans         (liftIO)
import          Data.Binary                 (Binary)
import          Data.MessagePack            (MessagePack (..))
import          Data.Void                   (Void)
import          GHC.Generics                (Generic)
import          Formatting                  (sformat, (%), shown, string)

import          Control.TimeWarp.Logging    (usingLoggerName, logDebug, logInfo,
                                             initLogging, Severity (Debug), logError)
import          Control.TimeWarp.Timed      (MonadTimed (wait), ms, sec', work,
                                             for, Second, till, fork_, runTimedIO)
import          Control.TimeWarp.Rpc        (MonadRpc (..), localhost, Listener (..),
                                             mkMessage, Port, NetworkAddress, send,
                                             listen, runTransfer, reply, listenOutbound,
                                             Method (..), mkRequest, runBinaryDialog)

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
    deriving (Generic, Binary, MessagePack)
$(mkMessage ''Ping)

data Pong = Pong
    deriving (Generic, Binary, MessagePack)
$(mkMessage ''Pong)

$(mkMessage ''Void)
$(mkRequest ''Ping ''Pong ''Void)

data EpicRequest = EpicRequest
    { num :: Int
    , msg :: String
    } deriving (Generic, Binary, MessagePack)
$(mkMessage ''EpicRequest)


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
