{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeApplications #-}

import           Control.Concurrent.Async    (forConcurrently)
import           Control.Lens                ((<&>))
import           Control.Monad               (forM, forM_, unless, void)
import           Control.Monad.Trans         (liftIO)
import           Control.Monad.Trans.Control (liftBaseWith)
import           GHC.IO.Encoding             (setLocaleEncoding, utf8)

import           Bench.Network.Commons       (MeasureEvent (..), Ping (..), Pong (..),
                                              logMeasure, removeFileIfExists,
                                              useBenchAsWorkingDirNotifier)
import           Control.TimeWarp.Logging    (initLoggingFromYaml, usingLoggerName)
import           Control.TimeWarp.Rpc        (BinaryP (..), Binding (AtConnTo),
                                              Listener (..), listen, localhost, runDialog,
                                              runTransfer, send)
import           Control.TimeWarp.Timed      (Millisecond, for, interval, runTimedIO,
                                              runTimedIO, sec, startTimer, wait)

main :: IO ()
main = runTimedIO . usingLoggerName "sender" $ do
    removeFileIfExists "sender.log"
    useBenchAsWorkingDirNotifier $
            initLoggingFromYaml "logging.yaml"
    liftIO $ setLocaleEncoding utf8

    let threadNum       = 5
    let msgNumPerServer = 1000
    let serverAddrs     = [(localhost, 3456)]
    let sendDelay       = 5 :: Millisecond
    let workingTime     = interval 5 sec

    let tasksIds         = [1..threadNum] <&>
                            \tid -> [tid, tid + threadNum .. msgNumPerServer]
    runConcurrently tasksIds $
        \msgIds -> runNetworking $ do
            closeConns <- forM serverAddrs $
                \serverAddr -> listen (AtConnTo serverAddr)
                    [ Listener $
                        \(Pong mid) -> logMeasure PongReceived mid
                    ]
            workTimer <- startTimer
            forM_ msgIds $
                \msgId -> do
                    wait (for sendDelay)
                    working <- workTimer
                    unless (working > workingTime) $
                        runConcurrently (zip [0..] serverAddrs) $
                            \(no, addr) -> do
                                let sMsgId = no * msgNumPerServer + msgId
                                logMeasure PingSent sMsgId
                                send addr $ Ping sMsgId
            -- wait for responses
            wait (for 1 sec)
            sequence_ closeConns

  where
    runNetworking = runTransfer . runDialog BinaryP
    runConcurrently l f = liftBaseWith $ \run -> void $ forConcurrently l (run . f)
