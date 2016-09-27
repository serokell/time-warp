{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE UndecidableInstances #-}

import           Control.Exception          (Exception)
import           Control.Monad              (forever, when, forM_)
import           Control.Monad.Catch        (MonadCatch, catch)
import           Control.Monad.Random       (StdGen, mkStdGen)
import           Control.Monad.Trans        (MonadIO (..), lift)
import           Control.Lens               (Iso', iso, (^.))
import           Formatting                 (sformat, shown, (%))
import           Data.Monoid                ((<>))
import           Data.Typeable              (Typeable)

import           Control.TimeWarp.Logging   (WithNamedLogger (..), usingLoggerName,
                                             logInfo, initLogging, setLoggerName,
                                             Severity (Info, Debug),
                                             LoggerName (..),
                                             logDebug, logWarning, LoggerNameBox)
import           Control.TimeWarp.Timed     (MonadTimed (..), schedule, ThreadId,
                                             killThread, at, for, sleepForever,
                                             Microsecond, runTimedIO, runTimedT, sec,
                                             interval, invoke, after)
import qualified Control.TimeWarp.Timed.TimedT as TimedT
import           Control.TimeWarp.Rpc       (MonadRpc (..), Port, NetworkAddress,
                                             Client, ServerT, call, method, runPureRpc,
                                             runMsgPackRpc, DelaysSpecifier,
                                             serverTypeRestriction1, MsgPackRpc,
                                             PureRpc)

main :: IO ()
main = do
    initLogging ["node"] Info
    let Context {..} = context
--    runRealMode $
    runEmulationMode (0 :: Microsecond) (mkStdGen 0) $
        setLoggerName "node" $ do
            forM_ [1 .. _nodeNum] $
                \no -> modifyLoggerName (<> LoggerName (show no)) $
                    fork $ launchNode context no
     
  where
    context =
        Context
            { _duration = interval 20 sec
            , _tokenDelay = interval 3 sec
            , _nodeNum = 3
            , _gotToken = return ()
            }

runRealMode :: LoggerNameBox MsgPackRpc () -> IO ()
runRealMode = runMsgPackRpc . usingLoggerName mempty

runEmulationMode
    :: DelaysSpecifier delays
    => delays -> StdGen -> PureRpc IO () -> IO ()
runEmulationMode delays gen = runPureRpc gen delays

nodePort :: Iso' Int Port
nodePort = iso (+2000) (subtract 2000)

fullAddr :: Iso' Port NetworkAddress
fullAddr = iso ("127.0.0.1", ) snd

class ( MonadTimed m
      , MonadRpc m
      , WithNamedLogger m
      , MonadIO m
      , MonadCatch m) => WorkMode m

instance ( MonadTimed m
         , MonadRpc m
         , WithNamedLogger m
         , MonadIO m
         , MonadCatch m) => WorkMode m

data Context = Context
    { _duration   :: Microsecond
    , _tokenDelay :: Microsecond
    , _nodeNum    :: Int
    , _gotToken   :: IO ()
    }

launchNode :: WorkMode m => Context -> Int -> m ()
launchNode Context{..} no = do
    logDebug $ sformat ("Launching node " % shown) no

    -- worker thread, which waits for signal from server thread
    -- to process token
    wtid <- modifyLoggerName (<> "worker") $
        fork $
            forever $ catch sleepForever onValueReceived

    -- server thread, which waits for token from other node and
    -- sends a signal to worker
    stid <- modifyLoggerName (<> "server") $
        fork $ do
            idr <- serverTypeRestriction1
            logDebug $ sformat ("Server up at " % shown) $ no ^. nodePort
            serve (no ^. nodePort) 
                [ method "token" $ idr $ acceptToken wtid
                ]

    -- kill all when testing finishes
    modifyLoggerName (<> "killer") $
        schedule (at _duration) $ do
            mapM_ killThread [wtid, stid]

    logInfo "Launched"

    -- initiate first token passing
    when (no == 1) $
        invoke (after 1 sec) $ do
            logInfo "Creating token"
            initPassingToken 1
  where
    onValueReceived (ValueReceived v) = do
        logInfo $ sformat ("Got token with value " % shown) v
        wait (for _tokenDelay)
        initPassingToken $ v + 1
    
    initPassingToken v = do
        let targetNode = no `mod` _nodeNum + 1
            targetAddr = targetNode ^. nodePort . fullAddr
        logDebug "Passing token"
        execClient targetAddr $ passToken v

    passToken :: Int -> Client ()
    passToken = call "token"

    acceptToken :: WorkMode m => ThreadId m -> Int -> ServerT m ()
    acceptToken tid value = do
        lift $ throwTo tid $ ValueReceived value

data SignalException = ValueReceived Int
    deriving (Show, Typeable)

instance Exception SignalException
