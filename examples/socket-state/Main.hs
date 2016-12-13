{-# LANGUAGE DeriveAnyClass  #-}
{-# LANGUAGE OverloadedLists #-}

-- | Example of simple ping-pong network application.

module Main where

import           Control.Concurrent       (forkIO)
import           Control.Concurrent.STM   (TVar, atomically, newTVar)
import           Control.Lens             ((<+=))
import           Control.Monad            (forM_, void)
import           Control.Monad.IO.Class   (MonadIO (liftIO))
import           Control.Monad.Loops      (whileM)
import           Data.Binary              (Binary)
import           Data.Data                (Data)
import           Data.Default             (def)
import           Data.Monoid              ((<>))
import           Data.String              (fromString)
import           Data.Time.Clock          (getCurrentTime)
import           Formatting               (sformat, shown, (%))
import           GHC.Generics             (Generic)
import           Serokell.Util.Concurrent (modifyTVarS, threadDelay)
import           System.Random
import           System.Wlog              (LoggerConfig (..), LoggerName, Severity (Info),
                                           logInfo, traverseLoggerConfig, usingLoggerName)

import           Control.TimeWarp.Rpc     (BinaryP, Binding (AtPort), Dialog,
                                           Listener (..), Message (..), Transfer, close,
                                           listen, localhost, messageName', plainBinaryP,
                                           runDialog, runTransfer, send, userStateR)
import           Control.TimeWarp.Timed   (after, for, invoke, runTimedIO, sec, wait)

type RequestsCounter = TVar Int

runNode :: LoggerName -> Dialog (BinaryP ()) (Transfer RequestsCounter) () -> IO ()
runNode name = void . forkIO . runTimedIO . usingLoggerName name . runTransfer (mkState)
             . runDialog plainBinaryP
    where
        mkState = atomically $ newTVar 0

ppLoggerConfig :: LoggerConfig
ppLoggerConfig = def { lcSubloggers = [("server", infoConf), ("client", infoConf)] }
  where
    infoConf = def { lcSeverity = Just Info }

initLogging :: MonadIO m => m ()
initLogging = traverseLoggerConfig id ppLoggerConfig Nothing

data Ping = Ping Int
    deriving (Generic, Binary, Data)

instance Message Ping where
    formatMessage = messageName'

-- | This example runs:
-- * server node which counts requests from each client separatelly
-- * 3 clients which send few messages, one per second
main :: IO ()
main = do
    initLogging

    runNode "server" $ do
        logInfo "Running..."

        stop <- listen (AtPort 4444)
            [ Listener $ \(Ping cid) -> do
                curTime <- liftIO getCurrentTime

                -- increment counter by 1, and return new value
                reqNo <- counterTic

                logInfo $ sformat ("Got Ping #"%shown%" from client #"%shown%" at "%shown)
                            reqNo cid curTime
            ]

        invoke (after 10 sec) stop

    forM_ ([1..3] :: [Int]) $
        \cid -> runNode ("client" <> fromString (show cid)) $ do
            logInfo "Running..."

            void $ whileM ruskaRuletka $ do
                 wait (for 1 sec)
                 send (localhost, 4444) $ Ping cid

            logInfo "Done"
            close (localhost, 4444)

    threadDelay $ sec 12
  where
    counterTic = do
        counter <- userStateR
        liftIO . atomically $ modifyTVarS counter $ id <+= 1

    -- | True with probability 2/3
    ruskaRuletka = liftIO $ ( > 0) <$> randomRIO (0, 2 :: Int)
