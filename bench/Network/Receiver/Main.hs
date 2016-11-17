import           Control.Monad.Trans      (liftIO)
import           Data.Monoid              ((<>))
import           GHC.IO.Encoding          (setLocaleEncoding, utf8)

import           Bench.Network.Commons    (MeasureEvent (..), Ping (..), logMeasure,
                                           removeFileIfExists,
                                           useBenchAsWorkingDirNotifier)
import           Control.TimeWarp.Logging (initLoggingFromYaml, logInfo, modifyLoggerName,
                                           usingLoggerName)
import           Control.TimeWarp.Rpc     (BinaryP (..), Binding (AtPort), Listener (..),
                                           listen, runDialog, runTransfer)
import           Control.TimeWarp.Timed   (for, runTimedIO, sec, wait)

main :: IO ()
main = runNode "receiver" $ do
    removeFileIfExists "receiver.log"
    useBenchAsWorkingDirNotifier $
        initLoggingFromYaml "logging.yaml"
    liftIO $ setLocaleEncoding utf8

    stopper <- listen (AtPort 3456)
        [ Listener $
            \(Ping mid) -> logMeasure PingReceived mid
        ]
    system $ logInfo "Launching server for 5 sec..."
    wait (for 5 sec)
    stopper

  where
    runNode name = runTimedIO . usingLoggerName name . runTransfer . runDialog BinaryP

    system = modifyLoggerName (<> "system")
