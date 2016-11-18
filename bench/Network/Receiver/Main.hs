module Main where

import           Control.Applicative        (empty)
import           Control.Monad              (forM_, when)
import           Control.Monad.Trans        (liftIO)
import           GHC.IO.Encoding            (setLocaleEncoding, utf8)

import           Bench.Network.Commons      (MeasureEvent (..), Ping (..), Pong (..),
                                             logMeasure)
import           Control.TimeWarp.Rpc       (BinaryP (..), Binding (AtPort),
                                             Listener (..), listen, reply, runDialog,
                                             runTransfer)
import           Control.TimeWarp.Timed     (for, runTimedIO, sec, wait)
import           Options.Applicative.Simple (simpleOptions)
import           System.Wlog                (parseLoggerConfig, traverseLoggerConfig,
                                             usingLoggerName)

import           ReceiverOptions            (Args (..), argsParser)

main :: IO ()
main = do
    (Args {..}, ()) <-
        simpleOptions
            "cardano-node"
            "PoS prototype node"
            "Use it!"
            argsParser
            empty

    runNode "receiver" $ do
        loggerConfig <- parseLoggerConfig logConfig
        traverseLoggerConfig id loggerConfig logsPrefix
        liftIO $ setLocaleEncoding utf8

        stopper <- listen (AtPort port)
            [ Listener $
                \(Ping mid) -> do
                    logMeasure PingReceived mid
                    when (not noPong) $ do
                        logMeasure PongSent mid
                        reply $ Pong mid
            ]
        wait (for duration sec)
        stopper

  where
    runNode name = runTimedIO . usingLoggerName name . runTransfer . runDialog BinaryP
