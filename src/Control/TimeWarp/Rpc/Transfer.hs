{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeSynonymInstances  #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE ViewPatterns          #-}

-- |
-- Module      : Control.TimeWarp.Rpc.Transfer
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC

module Control.TimeWarp.Rpc.Transfer
       ( Transfer (..)
       , TransferException (..)
       , runTransfer
       , runTransferS

       , Settings (..)
       , transferSettings
       , queueSize
       , reconnectPolicy

       -- TODO: do smth with this
       , JobManager
       , mkJobManager
       , addJob
       , interruptAllJobs
       , awaitAllJobs
       , stopAllJobs
       , addManagerAsJob
       , addThreadJob
       ) where

import qualified Control.Concurrent                 as C
import           Control.Concurrent.MVar            (MVar, modifyMVar, newEmptyMVar,
                                                     newMVar, putMVar, takeMVar)
import           Control.Concurrent.STM             (STM, atomically, check)
import qualified Control.Concurrent.STM.TBMChan     as TBM
import qualified Control.Concurrent.STM.TChan       as TC
import qualified Control.Concurrent.STM.TVar        as TV
import           Control.Lens                       (at, at, each, makeLenses, use, view,
                                                     (&), (.=), (.~), (<<+=), (<<.=),
                                                     (?=), (^.), (^..))
import           Control.Monad                      (forM_, forever, guard, unless, void,
                                                     when)
import           Control.Monad.Base                 (MonadBase)
import           Control.Monad.Catch                (Exception, MonadCatch,
                                                     MonadMask (mask), MonadThrow (..),
                                                     bracket, bracketOnError, catchAll,
                                                     finally, handleAll, onException,
                                                     throwM)
import           Control.Monad.Morph                (hoist)
import           Control.Monad.Reader               (ReaderT (..), ask)
import           Control.Monad.State                (State, StateT (..), runState,
                                                     runStateT)
import           Control.Monad.Trans                (MonadIO (..), lift)
import           Control.Monad.Trans.Control        (MonadBaseControl (..))
import qualified Data.ByteString                    as BS
import qualified Data.ByteString.Lazy               as BL
import           Data.Conduit                       (Sink, Source, ($$))
import           Data.Conduit.Binary                (sinkLbs, sourceLbs)
import           Data.Conduit.Network               (sinkSocket, sourceSocket)
import           Data.Conduit.TMChan                (sinkTBMChan, sourceTBMChan)
import qualified Data.IORef                         as IR
import           Data.List                          (intersperse)
import qualified Data.Map                           as M
import           Data.Maybe                         (fromJust, isJust)
import           Data.Streaming.Network             (acceptSafe, bindPortTCP,
                                                     getSocketFamilyTCP)
import           Data.Text                          (Text)
import           Data.Text.Buildable                (Buildable (build), build)
import           Data.Text.Encoding                 (decodeUtf8)
import           Data.Time.Units                    (toMicroseconds)
import           Data.Tuple                         (swap)
import           Data.Typeable                      (Typeable)
import           Formatting                         (bprint, builder, int, sformat, shown,
                                                     stext, string, (%))
-- import           GHC.IO.Exception                   (IOException (IOError), ioe_errno)
import qualified Network.Socket                     as NS

import           Control.TimeWarp.Logging           (LoggerNameBox, WithNamedLogger,
                                                     logDebug, logError, logInfo,
                                                     logWarning)
import           Control.TimeWarp.Rpc.MonadTransfer (Binding (..), MonadTransfer (..),
                                                     NetworkAddress, Port,
                                                     ResponseContext (..), ResponseT,
                                                     commLog, runResponseT, runResponseT,
                                                     sendRaw)
import           Control.TimeWarp.Timed             (Microsecond, MonadTimed, ThreadId,
                                                     TimedIO, for, fork, fork_, interval,
                                                     killThread, myThreadId, sec, wait)


-- * Related datatypes

-- ** Exceptions

data TransferException = AlreadyListeningOutbound Text
    deriving (Show, Typeable)

instance Exception TransferException

instance Buildable TransferException where
    build (AlreadyListeningOutbound addr) =
        bprint ("Already listening at outbound connection to "%stext) addr


data PeerClosedConnection = PeerClosedConnection
    deriving (Show, Typeable)

instance Exception PeerClosedConnection

instance Buildable PeerClosedConnection where
    build _ = "Peer closed connection"


-- * Job manager

type JobId = Int

type JobInterrupter = IO ()

type MarkJobFinished = IO ()

data JobsState = JobsState
    { _jmIsClosed :: Bool
      -- ^ whether close had been invoked
    , _jmJobs     :: M.Map JobId JobInterrupter
      -- ^ map with currently active jobs
    , _jmCounter  :: JobId
      -- ^ total number of allocated jobs ever
    }
$(makeLenses ''JobsState)

-- | Keeps set of jobs. Allows to stop jobs and wait till all of them finish.
type JobManager = TV.TVar JobsState

data InterruptType
    = Plain
    | Force
    | WithTimeout Microsecond (IO ())

modifyTVarS :: TV.TVar s -> State s a -> STM a
modifyTVarS t st = do
    s <- TV.readTVar t
    let (a, s') = runState st s
    TV.writeTVar t s'
    return a

-- | Hack to convert one monad to another, executes action no more than once.
convertMonad :: (MonadIO m, MonadTimed m, MonadIO n) => m () -> m (n ())
convertMonad action = do
    m <- liftIO newEmptyMVar
    fork_ $ liftIO (takeMVar m) >> action
    return $ liftIO $ putMVar m ()

mkJobManager :: MonadIO m => m JobManager
mkJobManager = liftIO . TV.newTVarIO $
    JobsState
    { _jmIsClosed = False
    , _jmJobs     = M.empty
    , _jmCounter  = 0
    }


-- | Remembers and starts given action.
-- Once `interruptAllJobs` called on this manager, if job is not completed yet,
-- `JobInterrupter` is invoked.
--
-- Given job *must* invoke given `MarkJobFinished` upon finishing, even if it was
-- interrupted.
--
-- If manager is already stopped, action would not start, and `JobInterrupter` would be
-- invoked.
addJob :: MonadIO m
       => JobManager -> JobInterrupter -> (MarkJobFinished -> m ()) -> m ()
addJob manager interrupter action = do
    jidm <- liftIO . atomically $ do
        st <- TV.readTVar manager
        let closed = st ^. jmIsClosed
        if closed
            then return Nothing
            else modifyTVarS manager $ do
                    no <- jmCounter <<+= 1
                    jmJobs . at no ?= interrupter
                    return $ Just no
    maybe (liftIO interrupter) (action . markReady) jidm
  where
    markReady jid = atomically $ do
        st <- TV.readTVar manager
        TV.writeTVar manager $ st & jmJobs . at jid .~ Nothing

-- | Invokes `JobInterrupter`s for all incompleted jobs.
-- Has no effect on second call.
interruptAllJobs :: MonadIO m => JobManager -> InterruptType -> m ()
interruptAllJobs m Plain = do
    jobs <- liftIO . atomically $ modifyTVarS m $ do
        wasClosed <- jmIsClosed <<.= True
        if wasClosed
            then return M.empty
            else use jmJobs
    liftIO $ sequence_ jobs
interruptAllJobs m Force = do
    interruptAllJobs m Plain
    liftIO . atomically $ modifyTVarS m $ jmJobs .= M.empty
interruptAllJobs m (WithTimeout delay onTimeout) = do
    interruptAllJobs m Plain
    void . liftIO . C.forkIO $ do
        C.threadDelay $ fromIntegral $ toMicroseconds delay
        done <- liftIO $ M.null . view jmJobs <$> TV.readTVarIO m
        unless done $ liftIO onTimeout >> interruptAllJobs m Force

-- | Waits for this manager to get closed and all registered jobs to invoke
-- `MaskForJobFinished`.
awaitAllJobs :: MonadIO m => JobManager -> m ()
awaitAllJobs m =
    liftIO . atomically $
        check =<< ((&&) <$> view jmIsClosed <*> M.null . view jmJobs) <$> TV.readTVar m

-- | Interrupts and then awaits for all jobs to complete.
stopAllJobs :: MonadIO m => JobManager -> m ()
stopAllJobs m = interruptAllJobs m Plain >> awaitAllJobs m

-- | Add second manager as a job to first manager.
addManagerAsJob :: (MonadIO m, MonadTimed m)
                => JobManager -> InterruptType -> JobManager -> m ()
addManagerAsJob manager intType managerJob = do
    interrupter <- convertMonad $ interruptAllJobs managerJob intType
    addJob manager interrupter $
        \ready -> fork_ $ awaitAllJobs managerJob >> liftIO ready

-- | Adds job executing in another thread, where interrupting kills the thread.
addThreadJob :: (MonadIO m,  MonadMask m, MonadTimed m) => JobManager -> m () -> m ()
addThreadJob manager action =
    mask $
        \unmask -> fork_ $ do
            tid <- myThreadId
            killer <- convertMonad $ killThread tid
            addJob manager killer $
                \markReady -> unmask action `finally` liftIO markReady

-- | Adds job executing in another thread, interrupting does nothing.
-- Usefull then work stops intself on interrupt, and just need to wait till it fully
-- stops.
addSafeThreadJob :: (MonadIO m,  MonadMask m, MonadTimed m) => JobManager -> m () -> m ()
addSafeThreadJob manager action =
    mask $
        \unmask -> fork_ $ addJob manager (return ()) $
            \markReady -> unmask action `finally` liftIO markReady

isInterrupted :: MonadIO m => JobManager -> m Bool
isInterrupted = liftIO . atomically . fmap (view jmIsClosed) . TV.readTVar

unlessInterrupted :: MonadIO m => JobManager -> m () -> m ()
unlessInterrupted m a = isInterrupted m >>= flip unless a


-- ** Connections

-- | Textual representation of peer node. For debugging purposes only.
type PeerAddr = Text

data OutputConnection = OutputConnection
    { outConnSend     :: forall m . (MonadIO m, MonadMask m, WithNamedLogger m)
                      => Source m BS.ByteString -> m ()
      -- ^ Function to send all data produced by source
    , outConnRec      :: forall m . (MonadIO m, MonadMask m, MonadTimed m,
                                     WithNamedLogger m)
                      => Sink BS.ByteString (ResponseT m) () -> m (m ())
      -- ^ Function to stark sink-listener, returns synchronous closer
    , outConnClose    :: IO ()
      -- ^ Closes socket, prevent any further manupulations
      -- with message queues
    , outConnAddr     :: PeerAddr
      -- ^ Address of socket on other side of net
    }


-- ** Settings

type FailsInRow = Int

data Settings = Settings
    { _queueSize       :: Int
    , _reconnectPolicy :: forall m . (WithNamedLogger m, MonadIO m)
                       => FailsInRow -> m (Maybe Microsecond)
    }
$(makeLenses ''Settings)

-- | Default settings, you can use it like @transferSettings { _queueSize = 1 }@
transferSettings :: Settings
transferSettings = Settings
    { _queueSize = 100
    , _reconnectPolicy =
        \failsInRow -> return $ guard (failsInRow < 3) >> Just (interval 3 sec)
    }


-- ** Manager

data Manager = Manager
    { _outputConn :: M.Map NetworkAddress OutputConnection
    }
$(makeLenses ''Manager)

initManager :: Manager
initManager =
    Manager
    { _outputConn = M.empty
    }


-- ** SocketFrame

-- | Keeps data which helps to improve socket to smart socket.
data SocketFrame = SocketFrame
    { sfPeerAddr   :: PeerAddr
    -- ^ Peer address, for debuging purposes only
    , sfInBusy     :: TV.TVar Bool
    -- ^ Whether someone already listens on this socket
    , sfInChan     :: TBM.TBMChan BS.ByteString
    -- ^ For incoming packs of bytes
    , sfOutChan    :: TBM.TBMChan (BL.ByteString, IO ())
     -- ^ For (packs of bytes to send, notification when bytes passed to socket)
    , sfJobManager :: JobManager
    }

mkSocketFrame :: MonadIO m => Settings -> PeerAddr -> m SocketFrame
mkSocketFrame settings sfPeerAddr = liftIO $ do
    sfInBusy     <- TV.newTVarIO False
    sfInChan     <- TBM.newTBMChanIO (_queueSize settings)
    sfOutChan    <- TBM.newTBMChanIO (_queueSize settings)
    sfJobManager <- mkJobManager
    return SocketFrame{..}

-- | Makes sender function in terms of @MonadTransfer@ for given `SocketFrame`.
-- This first extracts ready `Lazy.ByteString` from given source, and then passes it to
-- sending queue.
sfSend :: (MonadIO m, WithNamedLogger m)
       => SocketFrame -> Source m BS.ByteString -> m ()
sfSend SocketFrame{..} src = do
    lbs <- src $$ sinkLbs
    whenM (liftIO . atomically $ TBM.isFullTBMChan sfOutChan) $
      commLog . logWarning $ sformat ("Send channel for " % shown % " is full") sfPeerAddr
    whenM (liftIO . atomically $ TBM.isClosedTBMChan sfOutChan) $
      commLog . logWarning $ sformat ("Send channel for " % shown % " is closed, message wouldn't be sent") sfPeerAddr
    (notifier, awaiter) <- mkMonitor
    liftIO . atomically . TBM.writeTBMChan sfOutChan $ (lbs, atomically notifier)

    -- wait till data get consumed by socket, but immediatelly quit on socket close.
    liftIO . atomically $ do
        closed <- view jmIsClosed <$> TV.readTVar sfJobManager
        unless closed awaiter
  where
    mkMonitor = do
        t <- liftIO $ TV.newTVarIO False
        return ( TV.writeTVar t True
               , check =<< TV.readTVar t
               )
    whenM condM action = condM >>= flip when action

-- | Constructs function which allows infinitelly listens on given `SocketFrame` in terms of
-- `MonadTransfer`.
-- Attempt to use this function twice will end with `AlreadyListeningOutbound` error.
sfReceive :: (MonadIO m, MonadMask m, MonadTimed m, WithNamedLogger m)
          => SocketFrame -> Sink BS.ByteString (ResponseT m) () -> m (m ())
sfReceive sf@SocketFrame{..} sink = do
    busy <- liftIO . atomically $ TV.swapTVar sfInBusy True
    when busy $ throwM $ AlreadyListeningOutbound sfPeerAddr

    liManager <- mkJobManager
    onTimeout <- convertMonad logOnTimeout
    let interruptType = WithTimeout (interval 3 sec) onTimeout
    mask $ \unmask -> do
        addManagerAsJob sfJobManager interruptType liManager
        addThreadJob liManager $ unmask $ logOnErr $ do  -- TODO: disconnect / reconnect on error?
            flip runResponseT (sfResponseCtx sf) $
                sourceTBMChan sfInChan $$ sink
            commLog . logDebug $
                sformat ("Listening on socket to "%stext%" happily stopped") sfPeerAddr

    return $ stopAllJobs sfJobManager
  where
    logOnTimeout = commLog . logDebug $
        sformat ("While closing socket to "%stext%" listener "%
                 "worked for too long, closing with no regard to it") sfPeerAddr

sfClose :: SocketFrame -> IO ()
sfClose SocketFrame{..} = do
    interruptAllJobs sfJobManager Plain
    atomically $ do
        TBM.closeTBMChan sfInChan
        TBM.closeTBMChan sfOutChan
        clearInChan
  where
    clearInChan = TBM.tryReadTBMChan sfInChan >>= maybe (return ()) (const clearInChan)

sfOutputConn :: SocketFrame -> OutputConnection
sfOutputConn sf =
    OutputConnection
    { outConnSend  = sfSend sf
    , outConnRec   = sfReceive sf
    , outConnClose = sfClose sf
    , outConnAddr  = sfPeerAddr sf
    }

sfResponseCtx :: SocketFrame -> ResponseContext
sfResponseCtx sf =
    ResponseContext
    { respSend     = sfSend sf
    , respClose    = sfClose sf
    , respPeerAddr = sfPeerAddr sf
    }

-- | Starts workers, which connect channels in `SocketFrame` with real `NS.Socket`.
-- If error in any worker occured, it's propagaded.
sfProcessSocket :: (MonadIO m, MonadMask m, MonadTimed m, WithNamedLogger m)
                => SocketFrame -> NS.Socket -> m ()
sfProcessSocket SocketFrame{..} sock = do
    -- TODO: rewrite to async when MonadTimed supports it
    -- create channel to notify about error
    eventChan  <- liftIO TC.newTChanIO
    -- create worker threads
    stid <- fork $ reportErrors eventChan foreverSend $ sformat ("foreverSend on " % stext) sfPeerAddr
    rtid <- fork $ reportErrors eventChan foreverRec  $ sformat ("foreverRec on " % stext) sfPeerAddr
    commLog . logDebug $ sformat ("Start processing of socket to "%stext) sfPeerAddr
    -- check whether @isClosed@ keeps @True@
    ctid <- fork $ do
        liftIO . atomically $ check . view jmIsClosed =<< TV.readTVar sfJobManager
        liftIO . atomically $
            TC.writeTChan eventChan $ Right ()
        mapM_ killThread [stid, rtid]
    -- wait for error messages
    let onError e = do
            mapM_ killThread [stid, rtid, ctid]
            throwM e
    event <- liftIO . atomically $ TC.readTChan eventChan
    commLog . logDebug $ sformat ("Stop processing socket to "%stext) sfPeerAddr
    -- Left - worker error, Right - get closed
    either onError return event
    -- at this point workers are stopped
  where
    foreverSend = do
        datm <- liftIO . atomically $ TBM.readTBMChan sfOutChan
        forM_ datm $
            \dat@(bs, notif) -> do
                mask $ \unmask -> do
                    let pushback = liftIO . atomically $ TBM.unGetTBMChan sfOutChan dat
                    unmask (sourceLbs bs $$ sinkSocket sock) `onException` pushback
                    -- TODO: if get async exception here   ^, will send msg twice
                    liftIO notif
                foreverSend

    foreverRec = do
        hoist liftIO (sourceSocket sock) $$ sinkTBMChan sfInChan False
        unlessInterrupted sfJobManager $
            throwM PeerClosedConnection

    -- noteSend = iterM $ const $
    --     commLog . logDebug $
    --         sformat ("-> "%stext%" +1 message") sfPeerAddr

    -- noteRec = iterM $ const $
    --     commLog . logDebug $
    --         sformat ("<- "%stext%" +1 message") sfPeerAddr

    reportErrors eventChan action desc =
        action
          `catchAll` \e -> do
              commLog . logDebug $ sformat ("Caught error on " % stext % ": " % shown) desc e
              liftIO . atomically . TC.writeTChan eventChan . Left $ e


-- * Transfer

newtype Transfer a = Transfer
    { getTransfer :: ReaderT Settings (ReaderT (MVar Manager) (LoggerNameBox TimedIO)) a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadBase IO,
                MonadThrow, MonadCatch, MonadMask, MonadTimed, WithNamedLogger)

type instance ThreadId Transfer = C.ThreadId

-- | Run with specified settings
runTransferS :: Settings -> Transfer a -> LoggerNameBox TimedIO a
runTransferS s t = do m <- liftIO (newMVar initManager)
                      flip runReaderT m $ flip runReaderT s $ getTransfer t

runTransfer :: Transfer a -> LoggerNameBox TimedIO a
runTransfer = runTransferS transferSettings

modifyManager :: StateT Manager IO a -> Transfer a
modifyManager how = Transfer . lift $
    ask >>= liftIO . flip modifyMVar (fmap swap . runStateT how)


-- * Logic

buildSockAddr :: NS.SockAddr -> PeerAddr
buildSockAddr (NS.SockAddrInet port host) =
    let buildHost = mconcat . intersperse "."
                  . map build . (^.. each) . NS.hostAddressToTuple
    in  sformat (builder%":"%int) (buildHost host) port

buildSockAddr (NS.SockAddrInet6 port _ host _) =
    let buildHost6 = mconcat . intersperse "."
                   . map build . (^.. each) . NS.hostAddress6ToTuple
    in  sformat (builder%":"%int) (buildHost6 host) port

buildSockAddr (NS.SockAddrUnix addr) = sformat string addr

buildSockAddr (NS.SockAddrCan addr) = sformat ("can:"%int) addr

buildNetworkAddress :: NetworkAddress -> PeerAddr
buildNetworkAddress (host, port) = sformat (stext%":"%int) (decodeUtf8 host) port

listenInbound :: Port
              -> Sink BS.ByteString (ResponseT Transfer) ()
              -> Transfer (Transfer ())
listenInbound (fromIntegral -> port) sink = do
    jobManager <- mkJobManager

    -- launch server
    bracketOnError (liftIO $ bindPortTCP port "*") (liftIO . NS.close) $
        \lsocket -> mask $
            \unmask -> addThreadJob jobManager $
                flip finally (liftIO $ NS.close lsocket) . unmask $
                    logOnServeErr jobManager $
                        serve lsocket jobManager

    -- return closer
    convertMonad $ do
        commLog . logDebug $
            sformat ("Stopping server at "%int) port
        stopAllJobs jobManager
        commLog . logDebug $
            sformat ("Server at "%int%" fully stopped") port
  where
    serve lsocket jobManager = forever $
        bracketOnError (liftIO $ acceptSafe lsocket) (liftIO . NS.close . fst) $
            \(sock, addr) -> mask $
                \unmask -> fork_ $ do
                    settings <- Transfer ask
                    sf <- mkSocketFrame settings $ buildSockAddr addr
                    addManagerAsJob jobManager Plain (sfJobManager sf)

                    commLog . logDebug $
                        sformat ("New input connection: "%int%" <- "%stext)
                        port (sfPeerAddr sf)

                    finally (unmask $ processSocket sock sf jobManager)
                            (liftIO $ NS.close sock)

    logOnServeErr jm = handleAll $ \e -> do
            unlessInterrupted jm . logError $
                sformat ("Server at port "%int%" stopped with error "%shown) port e
            logDebug $ sformat ("Server at port "%int%" stopped with error "%shown) port e

    -- makes socket work, finishes once it's fully shutdown
    processSocket sock sf jm = do
        liftIO $ NS.setSocketOption sock NS.ReuseAddr 1

        _ <- sfReceive sf sink
        -- start `SocketFrame`'s' workers
        unlessInterrupted jm $ startProcessing sf jm $ do
            sfProcessSocket sf sock
            commLog . logInfo $
                sformat ("Happily closing input connection "%int%" <- "%stext)
                port (sfPeerAddr sf)

    startProcessing sf jm action =
        action `catchAll` \e -> do
            unlessInterrupted jm . commLog . logWarning $
                sformat ("Error in server socket "%int%" connected with "%stext%": "%shown)
                port (sfPeerAddr sf) e
            commLog . logDebug $
                sformat ("Error in server socket "%int%" connected with "%stext%": "%shown)
                port (sfPeerAddr sf) e


-- | Listens for incoming bytes on outbound connection.
-- Listening would occur until sink gets closed. Killing this thread won't help here.
-- Attempt to listen on socket which is already being listened causes exception.
-- Subscribtions could be implemented at layer above, where we operate with messages.
listenOutbound :: NetworkAddress
               -> Sink BS.ByteString (ResponseT Transfer) ()
               -> Transfer (Transfer ())
listenOutbound addr sink = do
    conn <- getOutConnOrOpen addr
    outConnRec conn sink

logOnErr :: (WithNamedLogger m, MonadIO m, MonadCatch m) => m () -> m ()
logOnErr = handleAll $ \e ->
    commLog . logDebug $ sformat ("Server error: "%shown) e


getOutConnOrOpen :: NetworkAddress -> Transfer OutputConnection
getOutConnOrOpen addr@(host, fromIntegral -> port) =
    mask $
        \unmask -> do
            (conn, sfm) <- ensureConnExist
            forM_ sfm $
                \sf -> addSafeThreadJob (sfJobManager sf) $
                    unmask (startWorker sf) `finally` releaseConn
            return conn
  where
    addrName = buildNetworkAddress addr

    ensureConnExist = do
        settings <- Transfer ask
        modifyManager $ do
            existing <- use $ outputConn . at addr
            if isJust existing
                then
                    return (fromJust existing, Nothing)
                else do
                    sf <- mkSocketFrame settings addrName
                    let conn = sfOutputConn sf
                    outputConn . at addr ?= conn
                    return (conn, Just sf)

    startWorker sf = do
        failsInRow <- liftIO $ IR.newIORef 0
        commLog . logDebug $ sformat ("Lively socket to "%stext%" created, processing")
            (sfPeerAddr sf)
        withRecovery sf failsInRow $
            bracket (liftIO $ fst <$> getSocketFamilyTCP host port NS.AF_UNSPEC)
                    (liftIO . NS.close) $
                    \sock -> do
                        liftIO $ IR.writeIORef failsInRow 0
                        commLog . logDebug $
                            sformat ("Established connection to "%stext) (sfPeerAddr sf)
                        sfProcessSocket sf sock

    withRecovery sf failsInRow action = catchAll action $ \e -> do
        closed <- isInterrupted (sfJobManager sf)
        unless closed $ do
            commLog . logWarning $
                sformat ("Error while working with socket to "%stext%": "%shown)
                    addrName e
            reconnect <- Transfer $ view reconnectPolicy
            fails <- liftIO $ succ <$> IR.readIORef failsInRow
            liftIO $ IR.writeIORef failsInRow fails
            maybeReconnect <- reconnect fails
            case maybeReconnect of
                Nothing ->
                    commLog . logWarning $
                        sformat ("Can't connect to "%shown%", closing connection") addr
                Just delay -> do
                    commLog . logWarning $
                        sformat ("Reconnect in "%shown) delay
                    wait (for delay)
                    withRecovery sf failsInRow action

    releaseConn = do
        modifyManager $ outputConn . at addr .= Nothing
        commLog . logDebug $
            sformat ("Socket to "%stext%" closed") addrName


instance MonadTransfer Transfer where
    sendRaw addr src = do
        conn <- getOutConnOrOpen addr
        outConnSend conn src

    listenRaw (AtPort   port) = listenInbound port
    listenRaw (AtConnTo addr) = listenOutbound addr

    -- closes asynchronuosly
    close addr = do
        maybeConn <- modifyManager . use $ outputConn . at addr
        liftIO $ forM_ maybeConn outConnClose


-- * Instances

instance MonadBaseControl IO Transfer where
    type StM Transfer a = StM (ReaderT (MVar Manager) TimedIO) a
    liftBaseWith io =
        Transfer $ liftBaseWith $ \runInBase -> io $ runInBase . getTransfer
    restoreM = Transfer . restoreM
