import           Data.Monoid              ((<>))
import           Formatting               (build, sformat, (%))

import           Bench.Network.Commons    (Ping (..), removeFileIfExists,
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

    stopper <- listen (AtPort 3456)
        [ justLogListener
        ]
    system $ logInfo "Launching server for 5 sec..."
    wait (for 5 sec)
    stopper

  where
    runNode name = runTimedIO . usingLoggerName name . runTransfer . runDialog BinaryP

    system = modifyLoggerName (<> "system")

    justLogListener = Listener $ \(Ping mid) -> logInfo $
        sformat ("Got message with id = "%build) mid
