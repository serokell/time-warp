import           Control.Monad            (forM_)
import           Control.Monad.Trans      (liftIO)
import           Data.List.Extra          (chunksOf)
import           GHC.IO.Encoding          (setLocaleEncoding, utf8)

import           Bench.Network.Commons    (MeasureEvent (..), Ping (..), logMeasure,
                                           removeFileIfExists,
                                           useBenchAsWorkingDirNotifier)
import           Control.TimeWarp.Logging (initLoggingFromYaml, usingLoggerName)
import           Control.TimeWarp.Rpc     (BinaryP (..), localhost, runDialog,
                                           runTransfer, send)
import           Control.TimeWarp.Timed   (for, fork_, runTimedIO, runTimedIO, sec, wait)

main :: IO ()
main = runNode "sender" $ do
    removeFileIfExists "sender.log"
    useBenchAsWorkingDirNotifier $
        initLoggingFromYaml "logging.yaml"
    liftIO $ setLocaleEncoding utf8

    let threadNum = 2
    let msgNum    = 10
    let taskIds   = chunksOf (msgNum `div` threadNum) [1..msgNum]
    forM_ taskIds $
        \msgIds -> fork_ . forM_ msgIds $
            \msgId -> do
                logMeasure PingSent msgId
                send (localhost, 3456) $ Ping msgId
    wait (for 2 sec)

  where
    runNode name = runTimedIO . usingLoggerName name . runTransfer . runDialog BinaryP
