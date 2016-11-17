import           Control.Monad            (forM_)
import           Control.Monad.Trans      (liftIO)
import           Data.List.Extra          (chunksOf)
import           GHC.IO.Encoding          (setLocaleEncoding, utf8)

import           Bench.Network.Commons    (MeasureEvent (..), Ping (..), Pong (..),
                                           logMeasure, removeFileIfExists,
                                           useBenchAsWorkingDirNotifier)
import           Control.TimeWarp.Logging (initLoggingFromYaml, usingLoggerName)
import           Control.TimeWarp.Rpc     (BinaryP (..), Binding (AtConnTo),
                                           Listener (..), listen, localhost, runDialog,
                                           runTransfer, send)
import           Control.TimeWarp.Timed   (for, fork_, runTimedIO, runTimedIO, sec, wait)

main :: IO ()
main = runTimedIO . usingLoggerName "sender" $ do
    removeFileIfExists "sender.log"
    useBenchAsWorkingDirNotifier $
        initLoggingFromYaml "logging.yaml"
    liftIO $ setLocaleEncoding utf8

    let threadNum = 5
    let msgNum    = 1000
    let taskIds   = chunksOf (msgNum `div` threadNum) [1..msgNum]
    forM_ taskIds $
        \msgIds -> fork_ . runNetworking $ do
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
    wait (for 10 sec)

  where
    runNetworking = runTransfer . runDialog BinaryP

    serverAddr = (localhost, 3456)
