{-# LANGUAGE FlexibleContexts      #-}
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
-- Maintainer  : Serokell <hi@serokell.io>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module provides implementation of `MonadTransfer`.
--
-- It operates with so called /lively sockets/, so that, if error occured while sending
-- or receiving, it would try to restore connection before reporting error.
--
-- When some data is sent for first time to given address, connection with single
-- lively-socket is created; it would be reused for further sends until closed.
--
-- Then server is getting up at some port, it creates single thread to handle incoming
-- connections, then for each input connection lively-socket is created.
--
-- TODO [TW-67]: close all connections upon quiting `Transfer` monad.
--
--
-- About lively sockets:
--
-- Lively socket keeps queue of byte chunks inside.
-- For given lively-socket, @send@ function just pushes chunks to send-queue, whenever
-- @receive@ infinitelly acquires chunks from receive-queue.
-- Those queues are connected to plain socket behind the scene.
--
-- Let's say lively socket to be /active/ if it successfully sends and receives
-- required data at the moment.
-- Upon becoming active, lively socket spawns `processing-observer` thread, which itself
-- spawns 3 threads: one pushes chunks from send-queue to socket, another one
-- pulls chunks from socket to receive-queue, and the last tracks whether socket was
-- closed.
-- Processor thread finishes in one of the following cases:
--
--    * One of it's children threads threw an error
--
--    * Socket was closed
--
-- If some error occures, lively socket goes to exceptional state (which is not expressed
-- in code, however), where it could be closed or provided with newly created plain socket
-- to continue work with and thus become active again.
--
-- UPGRADE-NOTE [TW-59]:
-- Currently, if an error in listener occures (parse error), socket gets closed.
-- Need to make it reconnect, if possible.


module Control.TimeWarp.Rpc.Transfer
       (
       -- * Transfer
         Transfer (..)
       , TransferException (..)
       , runTransfer
       , runTransferS

       -- * Settings
       , FailsInRow
       , Settings (..)
       ) where

import qualified Control.Concurrent                 as C
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
import           Control.Monad.State                (StateT (..))
import           Control.Monad.Trans                (MonadIO (..), lift)
import           Control.Monad.Trans.Control        (MonadBaseControl (..))
import qualified Data.ByteString                    as BS
import qualified Data.ByteString.Lazy               as BL
import           Data.Conduit                       (Sink, Source, ($$))
import           Data.Conduit.Binary                (sinkLbs, sourceLbs)
import           Data.Conduit.Network               (sinkSocket, sourceSocket)
import           Data.Conduit.TMChan                (sinkTBMChan, sourceTBMChan)
import           Data.Default                       (Default (..))
import qualified Data.IORef                         as IR
import           Data.List                          (intersperse)
import qualified Data.Map                           as M
import           Data.Streaming.Network             (acceptSafe, bindPortTCP,
                                                     getSocketFamilyTCP)
import           Data.Text                          (Text)
import           Data.Text.Buildable                (Buildable (build), build)
import           Data.Text.Encoding                 (decodeUtf8)
import           Data.Typeable                      (Typeable)
import           Formatting                         (bprint, builder, int, sformat, shown,
                                                     stext, string, (%))
-- import           GHC.IO.Exception                   (IOException (IOError), ioe_errno)
import qualified Network.Socket                     as NS
import           System.Wlog                        (CanLog, HasLoggerName, LoggerNameBox,
                                                     WithLogger, logDebug, logError,
                                                     logInfo, logWarning)

import           Control.TimeWarp.Rpc.MonadTransfer (Binding (..), MonadTransfer (..),
                                                     NetworkAddress, Port,
                                                     ResponseContext (..), ResponseT,
                                                     commLog, runResponseT, runResponseT,
                                                     sendRaw)
import           Control.TimeWarp.Timed             (Microsecond, MonadTimed, ThreadId,
                                                     TimedIO, for, fork, fork_, interval,
                                                     killThread, myThreadId, sec, wait)
import           Serokell.Util.Concurrent           (threadDelay)

-- * Related datatypes

-- ** Exceptions

-- | Error thrown if attempt to listen at already being listened connection is performed.
data TransferException = AlreadyListeningOutbound Text
    deriving (Show, Typeable)

instance Exception TransferException

instance Buildable TransferException where
    build (AlreadyListeningOutbound addr) =
        bprint ("Already listening at outbound connection to "%stext) addr

-- | Error thrown if peer was detected to close connection.
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

modifyTVarS :: TV.TVar s -> StateT s STM a -> STM a
modifyTVarS t st = do
    s <- TV.readTVar t
    (a, s') <- runStateT st s
    TV.writeTVar t s'
    return a

-- | Remembers monadic context of an action and transforms it to `IO`.
-- Note that any changes in context would be lost.
-- NOTE: interesting, why `monad-control` package lacks of this function, it seems cool
inCurrentContext :: (MonadBaseControl IO m, MonadIO n) => m () -> m (n ())
inCurrentContext action =
    liftBaseWith $ \runInIO -> return . liftIO . void $ runInIO action

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
        threadDelay delay
        done <- M.null . view jmJobs <$> TV.readTVarIO m
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
addManagerAsJob :: (MonadIO m, MonadTimed m, MonadBaseControl IO m)
                => JobManager -> InterruptType -> JobManager -> m ()
addManagerAsJob manager intType managerJob = do
    interrupter <- inCurrentContext $ interruptAllJobs managerJob intType
    addJob manager interrupter $
        \ready -> fork_ $ awaitAllJobs managerJob >> liftIO ready

-- | Adds job executing in another thread, where interrupting kills the thread.
addThreadJob :: (CanLog m, MonadIO m,  MonadMask m, MonadTimed m, MonadBaseControl IO m)
             => JobManager -> m () -> m ()
addThreadJob manager action =
    mask $
        \unmask -> fork_ $ do
            tid <- myThreadId
            killer <- inCurrentContext $ killThread tid
            addJob manager killer $
                \markReady -> unmask action `finally` liftIO markReady

-- | Adds job executing in another thread, interrupting does nothing.
-- Usefull then work stops itself on interrupt, and we just need to wait till it fully
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
    { outConnSend       :: forall m . (MonadIO m, MonadMask m, WithLogger m)
                        => Source m BS.ByteString -> m ()
      -- ^ Function to send all data produced by source
    , outConnRec        :: forall m . (MonadIO m, MonadMask m, MonadTimed m,
                                       MonadBaseControl IO m, WithLogger m)
                        => Sink BS.ByteString (ResponseT m) () -> m ()
      -- ^ Function to stark sink-listener, returns synchronous closer
    , outConnJobManager :: JobManager
      -- ^ Job manager for this connection
    , outConnAddr       :: PeerAddr
      -- ^ Address of socket on other side of net
    }


-- ** Settings

-- | Number of consequent fails while trying to establish connection.
type FailsInRow = Int

data Settings = Settings
    { queueSize       :: Int
    , reconnectPolicy :: forall m . (HasLoggerName m, MonadIO m)
                      => FailsInRow -> m (Maybe Microsecond)
    }

-- | Default settings, you can use it like @transferSettings { queueSize = 1 }@
instance Default Settings where
    def = Settings
        { queueSize = 100
        , reconnectPolicy =
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

-- | Keeps data required to implement so-called /lively socket/.
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
    -- ^ Job manager, tracks whether lively-socket wasn't closed.
    }

mkSocketFrame :: MonadIO m => Settings -> PeerAddr -> m SocketFrame
mkSocketFrame settings sfPeerAddr = liftIO $ do
    sfInBusy     <- TV.newTVarIO False
    sfInChan     <- TBM.newTBMChanIO (queueSize settings)
    sfOutChan    <- TBM.newTBMChanIO (queueSize settings)
    sfJobManager <- mkJobManager
    return SocketFrame{..}

-- | Makes sender function in terms of @MonadTransfer@ for given `SocketFrame`.
-- This first extracts ready `Lazy.ByteString` from given source, and then passes it to
-- sending queue.
sfSend :: (MonadIO m, WithLogger m)
       => SocketFrame -> Source m BS.ByteString -> m ()
sfSend SocketFrame{..} src = do
    lbs <- src $$ sinkLbs
    whenM (liftIO . atomically $ TBM.isFullTBMChan sfOutChan) $
        commLog . logWarning $
            sformat ("Send channel for "%shown%" is full") sfPeerAddr
    whenM (liftIO . atomically $ TBM.isClosedTBMChan sfOutChan) $
        commLog . logWarning $
            sformat ("Send channel for "%shown%" is closed, message wouldn't be sent")
                sfPeerAddr

    (notifier, awaiter) <- mkMonitor
    liftIO . atomically . TBM.writeTBMChan sfOutChan $ (lbs, atomically notifier)

    -- wait till data get consumed by socket, but immediatelly quit on socket closed.
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

-- | Constructs function which allows to infinitelly listen on given `SocketFrame`
-- in terms of `MonadTransfer`.
-- Attempt to use this function twice will end with `AlreadyListeningOutbound` error.
sfReceive :: (MonadIO m, MonadMask m, MonadTimed m, WithLogger m,
              MonadBaseControl IO m)
          => SocketFrame -> Sink BS.ByteString (ResponseT m) () -> m ()
sfReceive sf@SocketFrame{..} sink = do
    busy <- liftIO . atomically $ TV.swapTVar sfInBusy True
    when busy $ throwM $ AlreadyListeningOutbound sfPeerAddr

    liManager <- mkJobManager
    onTimeout <- inCurrentContext logOnTimeout
    let interruptType = WithTimeout (interval 3 sec) onTimeout
    mask $ \unmask -> do
        addManagerAsJob sfJobManager interruptType liManager
        addThreadJob liManager $ unmask $ logOnErr $ do  -- TODO: reconnect on error?
            flip runResponseT (sfMkResponseCtx sf) $
                sourceTBMChan sfInChan $$ sink
            commLog . logDebug $
                sformat ("Listening on socket to "%stext%" happily stopped") sfPeerAddr
  where
    logOnTimeout = commLog . logDebug $
        sformat ("While closing socket to "%stext%" listener "%
                 "worked for too long, closing with no regard to it") sfPeerAddr

    logOnErr = handleAll $ \e ->
        unlessInterrupted sfJobManager $ do
            commLog . logWarning $ sformat ("Server error: "%shown) e
            interruptAllJobs sfJobManager Plain


sfClose :: SocketFrame -> IO ()
sfClose SocketFrame{..} = do
    interruptAllJobs sfJobManager Plain
    atomically $ do
        TBM.closeTBMChan sfInChan
        TBM.closeTBMChan sfOutChan
        clearInChan
  where
    clearInChan = TBM.tryReadTBMChan sfInChan >>= maybe (return ()) (const clearInChan)

sfMkOutputConn :: SocketFrame -> OutputConnection
sfMkOutputConn sf =
    OutputConnection
    { outConnSend       = sfSend sf
    , outConnRec        = sfReceive sf
    , outConnJobManager = sfJobManager sf
    , outConnAddr       = sfPeerAddr sf
    }

sfMkResponseCtx :: SocketFrame -> ResponseContext
sfMkResponseCtx sf =
    ResponseContext
    { respSend     = sfSend sf
    , respClose    = sfClose sf
    , respPeerAddr = sfPeerAddr sf
    }

-- | Starts workers, which connect channels in `SocketFrame` with real `NS.Socket`.
-- If error in any worker occurs, it's propagated.
sfProcessSocket :: (MonadIO m, MonadMask m, MonadTimed m, WithLogger m)
                => SocketFrame -> NS.Socket -> m ()
sfProcessSocket SocketFrame{..} sock = do
    -- TODO: rewrite to async when MonadTimed supports it
    -- create channel to notify about error
    eventChan  <- liftIO TC.newTChanIO
    -- create worker threads
    stid <- fork $ reportErrors eventChan foreverSend $
        sformat ("foreverSend on "%stext) sfPeerAddr
    rtid <- fork $ reportErrors eventChan foreverRec $
        sformat ("foreverRec on "%stext) sfPeerAddr
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
    foreverSend =
        mask $ \unmask -> do
            datm <- liftIO . atomically $ TBM.readTBMChan sfOutChan
            forM_ datm $
                \dat@(bs, notif) -> do
                    let pushback = liftIO . atomically $ TBM.unGetTBMChan sfOutChan dat
                    unmask (sourceLbs bs $$ sinkSocket sock) `onException` pushback
                    -- TODO: if get async exception here   ^, will send msg twice
                    liftIO notif
                    unmask foreverSend

    foreverRec = do
        hoist liftIO (sourceSocket sock) $$ sinkTBMChan sfInChan False
        unlessInterrupted sfJobManager $
            throwM PeerClosedConnection

    reportErrors eventChan action desc =
        action `catchAll` \e -> do
            commLog . logDebug $ sformat ("Caught error on "%stext%": " % shown) desc e
            liftIO . atomically . TC.writeTChan eventChan . Left $ e


-- * Transfer

newtype Transfer a = Transfer
    { getTransfer :: ReaderT Settings
                        (ReaderT (TV.TVar Manager)
                            (LoggerNameBox
                                TimedIO
                            )
                        ) a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadBase IO,
                MonadThrow, MonadCatch, MonadMask, MonadTimed, CanLog, HasLoggerName)

type instance ThreadId Transfer = C.ThreadId

-- | Run with specified settings.
runTransferS :: Settings -> Transfer a -> LoggerNameBox TimedIO a
runTransferS s t = do m <- liftIO (TV.newTVarIO initManager)
                      flip runReaderT m $ flip runReaderT s $ getTransfer t

runTransfer :: Transfer a -> LoggerNameBox TimedIO a
runTransfer = runTransferS def

modifyManager :: StateT Manager STM a -> Transfer a
modifyManager how = Transfer . lift $
    ask >>= liftIO . atomically . flip modifyTVarS how


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
    inCurrentContext $ do
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
-- This thread doesn't block current thread. Use returned function to close relevant
-- connection.
listenOutbound :: NetworkAddress
               -> Sink BS.ByteString (ResponseT Transfer) ()
               -> Transfer (Transfer ())
listenOutbound addr sink = do
    conn <- getOutConnOrOpen addr
    outConnRec conn sink
    return $ stopAllJobs $ outConnJobManager conn


getOutConnOrOpen :: NetworkAddress -> Transfer OutputConnection
getOutConnOrOpen addr@(host, fromIntegral -> port) =
    mask $
        \unmask -> do
            (conn, sfm) <- ensureConnExist
            forM_ sfm $
                \sf -> addSafeThreadJob (sfJobManager sf) $
                    unmask (startWorker sf) `finally` releaseConn sf
            return conn
  where
    addrName = buildNetworkAddress addr

    ensureConnExist = do
        settings <- Transfer ask
        let getOr m act = maybe act (return . (, Nothing)) m

        -- two-phase connection creation
        -- 1. check whether connection already exists: if doesn't, make `SocketFrame`.
        -- 2. check again, if still absent push connection to pool
        mconn <- modifyManager $ use $ outputConn . at addr
        getOr mconn $ do
            sf <- mkSocketFrame settings addrName
            let conn = sfMkOutputConn sf
            modifyManager $ do
                mres <- use $ outputConn . at addr
                getOr mres $ do
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
            reconnect <- reconnectPolicy <$> Transfer ask
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

    releaseConn sf = do
        interruptAllJobs (sfJobManager sf) Plain
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
        forM_ maybeConn $
            \conn -> interruptAllJobs (outConnJobManager conn) Plain


-- * Instances

instance MonadBaseControl IO Transfer where
    type StM Transfer a = StM (ReaderT (TV.TVar Manager) TimedIO) a
    liftBaseWith io =
        Transfer $ liftBaseWith $ \runInBase -> io $ runInBase . getTransfer
    restoreM = Transfer . restoreM
