module Main where

import           Control.Monad              (forM_)
import           Control.Monad.Trans        (liftIO)
import           Data.List.Extra            (chunksOf)
import           GHC.IO.Encoding            (setLocaleEncoding, utf8)

import           Bench.Network.Commons      (MeasureEvent (..), Ping (..), Pong (..),
                                             logMeasure)
import           Control.TimeWarp.Rpc       (BinaryP (..), Binding (AtConnTo),
                                             Listener (..), listen, localhost, runDialog,
                                             runTransfer, send)
import           Control.TimeWarp.Timed     (for, fork_, runTimedIO, runTimedIO, sec,
                                             wait)
import           Options.Applicative.Simple (simpleOptions)
import           SenderOptions              (Args (..), argsParser)
import           System.Wlog                (parseLoggerConfig, traverseLoggerConfig,
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
    let taskIds   = chunksOf (msgNum `div` threadNum) [1..msgNum]
    let serverAddr = head recipients
    runNode "sender" $ do
        case logConfig of
          Just config -> do
            loggerConfig <- parseLoggerConfig config
            traverseLoggerConfig id loggerConfig logsPrefix
        liftIO $ setLocaleEncoding utf8

        forM_ taskIds $
            \msgIds -> fork_ $ do
                closeConn <- listen (AtConnTo serverAddr)
                    [ Listener $
                        \(Pong mid) -> logMeasure PongReceived mid
                    ]
                forM_ msgIds $
                    \msgId -> do
                        logMeasure PingSent msgId
                        send serverAddr $ Ping msgId
                wait (for 1 sec)
                closeConn
        wait (for duration sec)

  where
    runNode name = runTimedIO . usingLoggerName name . runTransfer . runDialog BinaryP
