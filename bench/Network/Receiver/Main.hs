import           Control.Monad.Trans      (liftIO)
import           GHC.IO.Encoding          (setLocaleEncoding, utf8)

import           Bench.Network.Commons    (MeasureEvent (..), Ping (..), Pong (..),
                                           logMeasure, removeFileIfExists,
                                           useBenchAsWorkingDirNotifier)
import           Control.TimeWarp.Logging (initLoggingFromYaml, usingLoggerName)
import           Control.TimeWarp.Rpc     (BinaryP (..), Binding (AtPort), Listener (..),
                                           listen, reply, runDialog, runTransfer)
import           Control.TimeWarp.Timed   (for, runTimedIO, sec, wait)

main :: IO ()
main = runNode "receiver" $ do
    removeFileIfExists "receiver.log"
    useBenchAsWorkingDirNotifier $
        initLoggingFromYaml "logging.yaml"
    liftIO $ setLocaleEncoding utf8

    stopper <- listen (AtPort 3456)
        [ Listener $
            \(Ping mid) -> do
                logMeasure PingReceived mid
                logMeasure PongSent mid
                reply $ Pong mid
        ]
    wait (for 10 sec)
    stopper

  where
    runNode name = runTimedIO . usingLoggerName name . runTransfer . runDialog BinaryP
