module Main where

import           Control.Applicative        (empty)
import           Control.Monad              (when)
import           Control.Monad.Trans        (liftIO)
import           GHC.IO.Encoding            (setLocaleEncoding, utf8)

import           Bench.Network.Commons      (MeasureEvent (..), Ping (..), Pong (..),
                                             loadLogConfig, logMeasure)
import           Control.TimeWarp.Rpc       (Binding (AtPort), Listener (..), listen,
                                             plainBinaryP, reply, runDialog, runTransfer)
import           Control.TimeWarp.Timed     (for, runTimedIO, sec, wait)
import           Options.Applicative.Simple (simpleOptions)
import           System.Wlog                (usingLoggerName)

import           ReceiverOptions            (Args (..), argsParser)

main :: IO ()
main = do
    (Args {..}, ()) <-
        simpleOptions
            "bench-receiver"
            "Server utility for benches"
            "Use it!"
            argsParser
            empty

    runNode "receiver" $ do
        loadLogConfig logsPrefix logConfig
        liftIO $ setLocaleEncoding utf8

        stopper <- listen (AtPort port)
            [ Listener $
                \(Ping mid payload) -> do
                    logMeasure PingReceived mid payload
                    when (not noPong) $ do
                        logMeasure PongSent mid payload
                        reply $ Pong mid payload
            ]
        wait (for duration sec)
        stopper

  where
    runNode name = runTimedIO . usingLoggerName name
                 . runTransfer . runDialog plainBinaryP
