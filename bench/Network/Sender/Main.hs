{-# LANGUAGE FlexibleContexts #-}

module Main where

import           Control.Applicative         (empty)
import           Control.Concurrent.Async    (forConcurrently)
import           Control.Monad               (forM, mzero, void, when)
import           Control.Monad.Trans         (lift, liftIO)
import           Control.Monad.Trans.Control (liftBaseWith)
import           Control.Monad.Trans.Maybe   (runMaybeT)
import           GHC.IO.Encoding             (setLocaleEncoding, utf8)
import           System.Random               (randomRIO)

import           Bench.Network.Commons       (MeasureEvent (..), Payload (..), Ping (..),
                                              Pong (..), loadLogConfig, logMeasure)
import           Control.TimeWarp.Rpc        (BinaryP (..), Binding (AtConnTo),
                                              Listener (..), listen, runDialog,
                                              runTransfer, send)
import           Control.TimeWarp.Timed      (Microsecond, for, interval, mcs,
                                              runTimedIO, runTimedIO, sec, startTimer,
                                              wait)
import           Options.Applicative.Simple  (simpleOptions)
import           SenderOptions               (Args (..), argsParser)
import           System.Wlog                 (usingLoggerName)

main :: IO ()
main = do
    (Args {..}, ()) <-
        simpleOptions
            "bench-sender"
            "Sender utility for benches"
            "Use it!"
            argsParser
            empty

    runNode "sender" $ do
        loadLogConfig logsPrefix logConfig
        liftIO $ setLocaleEncoding utf8

        let sendDelay :: Microsecond
            sendDelay = maybe 0 (\r -> interval ((1000000 :: Int) `div` r) mcs) msgRate
        let tasksIds  = [[tid, tid + threadNum .. msgNum] | tid <- [1..threadNum]]
        runConcurrently tasksIds $
            \msgIds -> runNetworking $ do
                closeConns <- forM recipients $
                    \addr -> listen (AtConnTo addr)
                        [ Listener $
                            \(Pong mid payload) -> logMeasure PongReceived mid payload
                        ]
                workTimer <- startTimer
                void . runMaybeT . forM msgIds $
                    \msgId -> do
                        lift $ wait (for sendDelay)
                        working <- lift workTimer
                        when (working > interval duration sec) mzero

                        lift $ runConcurrently (zip [0..] recipients) $
                            \(no, addr) -> do
                                let sMsgId  = no * msgNum + msgId
                                payload <- liftIO $
                                    Payload <$> randomRIO (0, payloadBound)
                                logMeasure PingSent sMsgId payload
                                send addr $ Ping sMsgId payload
                -- wait for responses
                wait (for 1 sec)
                sequence_ closeConns
  where
    runNode name = runTimedIO . usingLoggerName name
    runNetworking = runTransfer . runDialog BinaryP
    runConcurrently l f = liftBaseWith $ \run -> void $ forConcurrently l (run . f)
