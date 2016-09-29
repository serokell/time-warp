{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ConstraintKinds      #-}

import           Control.Exception          (Exception)
import           Control.Monad              (forever, when, forM_, unless, join)
import           Control.Monad.Catch        (MonadCatch, catch)
import           Control.Monad.Random       (StdGen, mkStdGen)
import qualified Control.Concurrent.STM.TVar as T
import           Control.Concurrent.STM     (atomically)
import           Control.Monad.Trans        (MonadIO (..), lift)
import           Control.Lens               (Iso', iso, (^.))
import           Formatting                 (sformat, shown, (%))
import           Data.Monoid                ((<>))
import           Data.Typeable              (Typeable)

import           Control.TimeWarp.Logging   (WithNamedLogger (..), usingLoggerName,
                                             logInfo, initLogging, setLoggerName,
                                             Severity (..),
                                             LoggerName (..),
                                             logDebug, logError, LoggerNameBox)
import           Control.TimeWarp.Timed     (MonadTimed (..), schedule, ThreadId,
                                             killThread, at, for, sleepForever,
                                             Microsecond, sec, ms,
                                             interval, invoke, after, fork_)
import           Control.TimeWarp.Rpc       (MonadRpc (..), Port, NetworkAddress,
                                             Client, ServerT, call, method, runPureRpc,
                                             runMsgPackRpc, DelaysSpecifier,
                                             serverTypeRestriction1, MsgPackRpc,
                                             PureRpc, getRandomTR, Delays (..),
                                             ConnectionOutcome (..))

-- * Launch parameters.

launchDuration :: Microsecond
launchDuration = interval 20 sec

tokenPassingDelay :: Microsecond
tokenPassingDelay = interval 3 sec

nodeNumber :: Int
nodeNumber = 3

allowedProgressDelay :: Microsecond
allowedProgressDelay = interval 5 sec

networkDelay :: (Microsecond, Microsecond)
networkDelay = (interval 1 ms, interval 5 ms)

emulationMode :: Bool
emulationMode = True

-- * Starter

main :: IO ()
main = do
    initLogging ["node", "observer"] Info
    if emulationMode
        then runEmulationMode delays (mkStdGen 0) scenario
        else runRealMode scenario
  where
    scenario :: WorkMode m => m ()
    scenario = do
        setLoggerName "node" $ do
            forM_ [1 .. nodeNumber] $
                \no -> modifyLoggerName (<> LoggerName (show no)) $
                    fork $ launchNode no

        setLoggerName ("observer" <> "progress") $
            fork_ $
                launchObserver
    delays = Delays $
                \dest _ -> 
                    if dest == (observerPort ^. fullAddr)
                    then return $ ConnectedIn 0
                    else ConnectedIn <$> getRandomTR networkDelay

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

type WorkMode m
    = ( MonadTimed m
      , MonadRpc m
      , WithNamedLogger m
      , MonadIO m
      , MonadCatch m)

-- * Nodes

type TokenValue = Int

launchNode :: WorkMode m => Int -> m ()
launchNode no = do
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
        schedule (at launchDuration) $ do
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
        execClient ("127.0.0.1", observerPort) $ noteTokenCall v
        wait (for tokenPassingDelay)
        initPassingToken $ v + 1

    initPassingToken v = do
        let targetNode = no `mod` nodeNumber + 1
            targetAddr = targetNode ^. nodePort . fullAddr
        logDebug "Passing token"
        execClient targetAddr $ passToken v

    passToken :: TokenValue -> Client ()
    passToken = call "token"

    acceptToken :: WorkMode m => ThreadId m -> TokenValue -> ServerT m ()
    acceptToken tid value = do
        lift . throwTo tid $ ValueReceived value

data SignalException = ValueReceived Int
    deriving (Show, Typeable)

instance Exception SignalException

-- * Observer, checks for global predicates.

observerPort :: Int
observerPort = 5000

launchObserver :: WorkMode m => m ()
launchObserver = do
    lastProgress <- liftIO $ T.newTVarIO (0, 0)

    -- server which listens whether token value was changed
    stid <- modifyLoggerName (<> "server") $
        fork $ do
            idr <- serverTypeRestriction1
            serve observerPort
                [method "noteToken" $ idr $ noteTokenMethod lastProgress
                ]

    -- periodically checks for progress
    ctid <- modifyLoggerName (<> "checker") $
        fork . forever $ do
            wait (for 1 sec)
            (lastTime, value) <- liftIO $ T.readTVarIO lastProgress
            time <- virtualTime
            when (time - lastTime > allowedProgressDelay) $
                logError $
                    sformat ("Token value (" % shown % ") hasn't changed " %
                             "since " % shown % shown) value lastTime time

    logInfo "Launched"

    -- kill all when testing finishes
    modifyLoggerName (<> "killer") $
        schedule (at launchDuration) $ do
            mapM_ killThread [stid, ctid]


noteTokenMethod
    :: WorkMode m
    => T.TVar (Microsecond, TokenValue) -> TokenValue -> ServerT m ()
noteTokenMethod progressBox value = lift $ do
    time <- virtualTime
    join . liftIO . atomically $ do
        (_, wasValue) <- T.readTVar progressBox
        T.writeTVar progressBox (time, value)
        return $
            unless (value == wasValue + 1) $
                logError $ sformat ("Wrong token value: expected " % shown %
                                    " but got " % shown) (wasValue + 1) value

noteTokenCall :: TokenValue -> Client ()
noteTokenCall = call "noteToken"
