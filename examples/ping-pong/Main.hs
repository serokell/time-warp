{-# LANGUAGE DeriveAnyClass  #-}
{-# LANGUAGE OverloadedLists #-}

-- | Example of simple ping-pong network application.

module Main where

import           Control.Concurrent       (forkIO)
import           Control.Monad            (void)
import           Control.Monad.IO.Class   (MonadIO (liftIO))

import           Data.Binary              (Binary)
import           Data.Data                (Data)
import           Data.Default             (def)
import           Data.Time.Clock          (getCurrentTime)

import           Formatting               (sformat, shown, (%))
import           GHC.Generics             (Generic)
import           Serokell.Util.Concurrent (threadDelay)
import           System.Wlog              (LoggerConfig (..), LoggerName, Severity (Info),
                                           logInfo, traverseLoggerConfig, usingLoggerName)

import           Control.TimeWarp.Rpc     (BinaryP, Binding (AtPort), Dialog,
                                           Listener (..), Message (..), Transfer, listen,
                                           localhost, messageName', plainBinaryP,
                                           runDialog, runTransfer, send)
import           Control.TimeWarp.Timed   (for, runTimedIO, sec, wait)

runNode :: LoggerName -> Dialog (BinaryP ()) Transfer () -> IO ()
runNode name = void . forkIO . runTimedIO . usingLoggerName name . runTransfer . runDialog plainBinaryP

ppLoggerConfig :: LoggerConfig
ppLoggerConfig = def { lcSubloggers = [("ping", infoConf), ("pong", infoConf)] }
  where
    infoConf = def { lcSeverity = Just Info }

initLogging :: MonadIO m => m ()
initLogging = traverseLoggerConfig id ppLoggerConfig Nothing

data Ping = Ping
    deriving (Generic, Binary, Data)

data Pong = Pong
    deriving (Generic, Binary, Data)

instance Message Ping where
    formatMessage = messageName'

instance Message Pong where
    formatMessage = messageName'

main :: IO ()
main = do
    initLogging

    runNode "ping" $ do
        logInfo "Running..."

        wait (for 2 sec)
        send (localhost, 5555) Ping

        void $ listen (AtPort 4444)
            [ Listener $ \Pong -> do
                curTime <- liftIO getCurrentTime
                logInfo $ sformat ("Get Pong at "%shown) curTime
            ]

    runNode "pong" $ do
        logInfo "Running..."

        void $ listen (AtPort 5555)
            [ Listener $ \Ping -> do
                curTime <- liftIO getCurrentTime
                logInfo $ sformat ("Get Ping at "%shown) curTime
                send (localhost, 4444) Pong
            ]

    threadDelay $ sec 5
