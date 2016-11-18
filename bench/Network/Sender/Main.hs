{-# LANGUAGE FlexibleContexts #-}

module Main where

import           Control.Concurrent.Async    (forConcurrently)
import           Control.Lens                ((<&>))
import           Control.Monad               (forM, forM_, unless, void)
import           Control.Monad.Trans         (liftIO)
import           Control.Monad.Trans.Control (liftBaseWith)
import           Data.List.Extra             (chunksOf)
import           GHC.IO.Encoding             (setLocaleEncoding, utf8)

import           Bench.Network.Commons       (MeasureEvent (..), Ping (..), Pong (..),
                                              logMeasure)
import           Control.TimeWarp.Rpc        (BinaryP (..), Binding (AtConnTo),
                                              Listener (..), listen, localhost, runDialog,
                                              runTransfer, send)
import           Control.TimeWarp.Timed      (Millisecond, for, fork_, interval,
                                              runTimedIO, runTimedIO, sec, startTimer,
                                              wait)
import           Options.Applicative.Simple  (simpleOptions)
import           SenderOptions               (Args (..), argsParser)
import           System.Wlog                 (parseLoggerConfig, traverseLoggerConfig,
                                              usingLoggerName)

main :: IO ()
main = do
    (Args {..}, ()) <-
        simpleOptions
            "cardano-node"
            "PoS prototype node"
            "Use it!"
            argsParser
            (return ())

    runNode "sender" $ do
        case logConfig of
          Just config -> do
            loggerConfig <- parseLoggerConfig config
            traverseLoggerConfig id loggerConfig logsPrefix
        liftIO $ setLocaleEncoding utf8

        let sendDelay   = 5 :: Millisecond
        let tasksIds    = [1..threadNum] <&>
                                \tid -> [tid, tid + threadNum .. msgNum]
        runConcurrently tasksIds $
            \msgIds -> runNetworking $ do
                closeConns <- forM recipients $
                    \addr -> listen (AtConnTo addr)
                        [ Listener $
                            \(Pong mid) -> logMeasure PongReceived mid
                        ]
                workTimer <- startTimer
                forM_ msgIds $
                    \msgId -> do
                        wait (for sendDelay)
                        working <- workTimer
                        unless (working > interval duration sec) $
                            runConcurrently (zip [0..] recipients) $
                                \(no, addr) -> do
                                    let sMsgId = no * msgNum + msgId
                                    logMeasure PingSent sMsgId
                                    send addr $ Ping sMsgId
                -- wait for responses
                wait (for 1 sec)
                sequence_ closeConns
  where
    runNode name = runTimedIO . usingLoggerName name
    runNetworking = runTransfer . runDialog BinaryP
    runConcurrently l f = liftBaseWith $ \run -> void $ forConcurrently l (run . f)
