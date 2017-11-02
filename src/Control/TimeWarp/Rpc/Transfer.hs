{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}
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
       , ConnectionPool
       , runTransfer
       , runTransferS
       , runTransferRaw
       , getConnPool

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
                                                     (.=), (?=), (^..))
import           Control.Monad                      (forM_, forever, guard, unless, when)
import           Control.Monad.Base                 (MonadBase)
import           Control.Monad.Catch                (Exception, MonadCatch,
                                                     MonadMask (mask), MonadThrow (..),
                                                     bracket, bracketOnError, catchAll,
                                                     finally, handleAll, onException,
                                                     throwM)
import           Control.Monad.Morph                (hoist)
import           Control.Monad.Reader               (MonadReader (ask), ReaderT (..))
import           Control.Monad.State.Strict         (StateT (..))
import           Control.Monad.Trans                (MonadIO (..), lift)
import           Control.Monad.Trans.Control        (MonadBaseControl (..))

import           Control.Monad.Extra                (whenM)
import qualified Data.ByteString                    as BS
import qualified Data.ByteString.Lazy               as BL
import           Data.Conduit                       (Sink, Source, ($$))
import           Data.Conduit.Binary                (sinkLbs, sourceLbs)
import           Data.Conduit.Network               (sinkSocket, sourceSocket)
import           Data.Conduit.TMChan                (sinkTBMChan, sourceTBMChan)
import           Data.Default                       (Default (..))
import           Data.HashMap.Strict                (HashMap)
import qualified Data.IORef                         as IR
import           Data.List                          (intersperse)
import           Data.Streaming.Network             (acceptSafe, bindPortTCP,
                                                     getSocketFamilyTCP)
import           Data.Text                          (Text)
import           Data.Text.Buildable                (Buildable (build), build)
import           Data.Text.Encoding                 (decodeUtf8)
import           Data.Typeable                      (Typeable)
import           Formatting                         (bprint, builder, int, sformat, shown,
                                                     stext, string, (%))
import qualified Network.Socket                     as NS
import           Serokell.Util.Base                 (inCurrentContext)
import           Serokell.Util.Concurrent           (modifyTVarS)
import           System.Wlog                        (CanLog, HasLoggerName, LoggerNameBox,
                                                     Severity (..), WithLogger, logDebug,
                                                     logInfo, logMessage, logWarning)

import           Control.TimeWarp.Manager           (InterruptType (..), JobCurator (..),
                                                     addManagerAsJob, addSafeThreadJob,
                                                     addThreadJob, interruptAllJobs,
                                                     isInterrupted, jcIsClosed,
                                                     mkJobCurator, stopAllJobs,
                                                     unlessInterrupted)
import           Control.TimeWarp.Rpc.MonadTransfer (Binding (..), MonadTransfer (..),
                                                     NetworkAddress, Port,
                                                     ResponseContext (..), ResponseT,
                                                     commLog, runResponseT, runResponseT,
                                                     sendRaw)
import           Control.TimeWarp.Timed             (Microsecond, MonadTimed, ThreadId,
                                                     TimedIO, for, fork, fork_, interval,
                                                     killThread, sec, wait)

-- * Util

logSeverityUnlessClosed :: (WithLogger m, MonadIO m)
                        => Severity -> JobCurator -> Text -> m ()
logSeverityUnlessClosed severityIfNotClosed jm msg = do
    closed <- isInterrupted jm
    let severity = if closed then severityIfNotClosed else Debug
    logMessage severity msg


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

-- ** Connections

-- | Textual representation of peer node. For debugging purposes only.
type PeerAddr = Text

data OutputConnection s = OutputConnection
    { outConnSend       :: forall m . (MonadIO m, MonadMask m, WithLogger m)
                        => Source m BS.ByteString -> m ()
      -- ^ Function to send all data produced by source
    , outConnRec        :: forall m . (MonadIO m, MonadMask m, MonadTimed m,
                                       MonadBaseControl IO m, WithLogger m)
                        => Sink BS.ByteString (ResponseT s m) () -> m ()
      -- ^ Function to stark sink-listener, returns synchronous closer
    , outConnJobCurator :: JobCurator
      -- ^ Job manager for this connection
    , outConnAddr       :: PeerAddr
      -- ^ Address of socket on other side of net
    , outConnUserState  :: s
      -- ^ State binded to socket
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


-- ** ConnectionPool

newtype ConnectionPool s = ConnectionPool
    { _outputConn :: HashMap NetworkAddress (OutputConnection s)
    }

makeLenses ''ConnectionPool

initConnectionPool :: ConnectionPool s
initConnectionPool =
    ConnectionPool
    { _outputConn = mempty
    }

-- ** SocketFrame

-- | Keeps data required to implement so-called /lively socket/.
data SocketFrame s = SocketFrame
    { sfPeerAddr   :: PeerAddr
    -- ^ Peer address, for debuging purposes only
    , sfInBusy     :: TV.TVar Bool
    -- ^ Whether someone already listens on this socket
    , sfInChan     :: TBM.TBMChan BS.ByteString
    -- ^ For incoming packs of bytes
    , sfOutChan    :: TBM.TBMChan (BL.ByteString, IO ())
    -- ^ For (packs of bytes to send, notification when bytes passed to socket)
    , sfJobCurator :: JobCurator
    -- ^ Job manager, tracks whether lively-socket wasn't closed.
    , sfUserState  :: s
    }

mkSocketFrame :: MonadIO m
              => Settings -> IO s -> PeerAddr -> m (SocketFrame s)
mkSocketFrame settings mkUserState sfPeerAddr = liftIO $ do
    sfInBusy     <- TV.newTVarIO False
    sfInChan     <- TBM.newTBMChanIO (queueSize settings)
    sfOutChan    <- TBM.newTBMChanIO (queueSize settings)
    sfJobCurator <- mkJobCurator
    sfUserState  <- mkUserState
    return SocketFrame{..}

-- | Makes sender function in terms of @MonadTransfer@ for given `SocketFrame`.
-- This first extracts ready `Lazy.ByteString` from given source, and then passes it to
-- sending queue.
sfSend :: (MonadIO m, WithLogger m)
       => SocketFrame s -> Source m BS.ByteString -> m ()
sfSend SocketFrame{..} src = do
    lbs <- src $$ sinkLbs
    logQueueState
    (notifier, awaiter) <- mkMonitor
    liftIO . atomically . TBM.writeTBMChan sfOutChan $ (lbs, atomically notifier)

    -- wait till data get consumed by socket, but immediatelly quit on socket
    -- get closed.
    liftIO . atomically $ do
        let jm = getJobCurator sfJobCurator
        closed <- view jcIsClosed <$> TV.readTVar jm
        unless closed awaiter
  where
    -- creates pair (@notifier@, @awaiter@), where @awaiter@ blocks thread
    -- until @notifier@ is called.
    mkMonitor = do
        t <- liftIO $ TV.newTVarIO False
        return ( TV.writeTVar t True
               , check =<< TV.readTVar t
               )

    logQueueState = do
        whenM (liftIO . atomically $ TBM.isFullTBMChan sfOutChan) $
            commLog . logWarning $
                sformat ("Send channel for "%shown%" is full") sfPeerAddr
        whenM (liftIO . atomically $ TBM.isClosedTBMChan sfOutChan) $
            commLog . logWarning $
                sformat ("Send channel for "%shown%" is closed, message wouldn't be sent")
                    sfPeerAddr

-- | Constructs function which allows to infinitelly listen on given `SocketFrame`
-- in terms of `MonadTransfer`.
-- Attempt to use this function twice will end with `AlreadyListeningOutbound` error.
sfReceive :: (MonadIO m, MonadMask m, MonadTimed m, WithLogger m,
              MonadBaseControl IO m)
          => SocketFrame s -> Sink BS.ByteString (ResponseT s m) () -> m ()
sfReceive sf@SocketFrame{..} sink = do
    busy <- liftIO . atomically $ TV.swapTVar sfInBusy True
    when busy $ throwM $ AlreadyListeningOutbound sfPeerAddr

    liManager <- mkJobCurator
    onTimeout <- inCurrentContext logOnInterruptTimeout
    let interruptType = WithTimeout (interval 3 sec) onTimeout
    mask $ \unmask -> do
        addManagerAsJob sfJobCurator interruptType liManager
        addThreadJob liManager $ unmask $ logOnErr $ do  -- TODO: reconnect on error?
            (sourceTBMChan sfInChan $$ sink) `runResponseT` sfMkResponseCtx sf
            logListeningHappilyStopped
  where
    logOnErr = handleAll $ \e ->
        unlessInterrupted sfJobCurator $ do
            commLog . logWarning $ sformat ("Server error: "%shown) e
            interruptAllJobs sfJobCurator Plain

    logOnInterruptTimeout = commLog . logDebug $
        sformat ("While closing socket to "%stext%" listener "%
                 "worked for too long, closing with no regard to it") sfPeerAddr

    logListeningHappilyStopped =
        commLog . logDebug $
            sformat ("Listening on socket to "%stext%" happily stopped") sfPeerAddr

sfClose :: SocketFrame s -> IO ()
sfClose SocketFrame{..} = do
    interruptAllJobs sfJobCurator Plain
    atomically $ do
        TBM.closeTBMChan sfInChan
        TBM.closeTBMChan sfOutChan
        clearInChan
  where
    clearInChan = TBM.tryReadTBMChan sfInChan >>= maybe (return ()) (const clearInChan)

sfMkOutputConn :: SocketFrame s -> OutputConnection s
sfMkOutputConn sf =
    OutputConnection
    { outConnSend       = sfSend sf
    , outConnRec        = sfReceive sf
    , outConnJobCurator = sfJobCurator sf
    , outConnAddr       = sfPeerAddr sf
    , outConnUserState  = sfUserState sf
    }

sfMkResponseCtx :: SocketFrame s -> ResponseContext s
sfMkResponseCtx sf =
    ResponseContext
    { respSend      = sfSend sf
    , respClose     = sfClose sf
    , respPeerAddr  = sfPeerAddr sf
    , respUserState = sfUserState sf
    }

-- | Starts workers, which connect channels in `SocketFrame` with real `NS.Socket`.
-- If error in any worker occurs, it's propagated.
sfProcessSocket :: (MonadIO m, MonadMask m, MonadTimed m, WithLogger m)
                => SocketFrame s -> NS.Socket -> m ()
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
        let jm = getJobCurator sfJobCurator
        liftIO . atomically $ check . view jcIsClosed =<< TV.readTVar jm
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
        unlessInterrupted sfJobCurator $
            throwM PeerClosedConnection

    reportErrors eventChan action desc =
        action `catchAll` \e -> do
            commLog . logDebug $ sformat ("Caught error on "%stext%": " % shown) desc e
            liftIO . atomically . TC.writeTChan eventChan . Left $ e


-- * Transfer

newtype Transfer s a = Transfer
    { getTransfer :: ReaderT Settings
                        (ReaderT (TV.TVar (ConnectionPool s))
                            (ReaderT (IO s)
                                (LoggerNameBox
                                    TimedIO
                                )
                            )
                        ) a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadBase IO,
                MonadThrow, MonadCatch, MonadMask, MonadTimed, CanLog, HasLoggerName)

type instance ThreadId (Transfer s) = C.ThreadId

runTransferRaw
  :: Settings
  -> TV.TVar (ConnectionPool s)
  -> IO s
  -> Transfer s a
  -> LoggerNameBox TimedIO a
runTransferRaw s m us t =
    flip runReaderT us $ flip runReaderT m $ flip runReaderT s $
    getTransfer t

-- | Run with specified settings.
runTransferS :: Settings -> IO s -> Transfer s a -> LoggerNameBox TimedIO a
runTransferS s us t = do
    m <- liftIO (TV.newTVarIO initConnectionPool)
    runTransferRaw s m us t

-- | Run `Transfer`, with a way to create initial state for socket.
runTransfer :: IO s -> Transfer s a -> LoggerNameBox TimedIO a
runTransfer = runTransferS def

modifyManager :: StateT (ConnectionPool s) STM a -> Transfer s a
modifyManager how = Transfer . lift $
    ask >>= liftIO . atomically . flip modifyTVarS how

getConnPool :: Transfer s (TV.TVar (ConnectionPool s))
getConnPool = Transfer $ lift ask

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
              -> Sink BS.ByteString (ResponseT s (Transfer s)) ()
              -> Transfer s (Transfer s ())
listenInbound (fromIntegral -> port) sink = do
    serverJobCurator <- mkJobCurator
    -- launch server
    bracketOnError (liftIO $ bindPortTCP port "*") (liftIO . NS.close) $
        \lsocket -> mask $
            \unmask -> addThreadJob serverJobCurator $
                flip finally (liftIO $ NS.close lsocket) . unmask $
                    handleAll (logOnServerError serverJobCurator) $
                        serve lsocket serverJobCurator
    -- return closer
    inCurrentContext $ do
        commLog . logDebug $ sformat ("Stopping server at "%int) port
        stopAllJobs serverJobCurator
        commLog . logDebug $ sformat ("Server at "%int%" fully stopped") port
  where
    serve lsocket serverJobCurator = forever $
        bracketOnError (liftIO $ acceptSafe lsocket) (liftIO . NS.close . fst) $
            \(sock, addr) -> mask $
                \unmask -> fork_ $ do
                    settings <- Transfer ask
                    us <- Transfer . lift . lift $ ask
                    sf@SocketFrame{..} <- mkSocketFrame settings us $ buildSockAddr addr
                    addManagerAsJob serverJobCurator Plain sfJobCurator

                    logNewInputConnection sfPeerAddr
                    unmask (processSocket sock sf serverJobCurator)
                        `finally` liftIO (NS.close sock)

    -- makes socket work, finishes once it's fully shutdown
    processSocket sock sf@SocketFrame{..} jc = do
        liftIO $ NS.setSocketOption sock NS.ReuseAddr 1

        sfReceive sf sink
        unlessInterrupted jc $
            handleAll (logErrorOnServerSocketProcessing jc sfPeerAddr) $ do
                sfProcessSocket sf sock
                logInputConnHappilyClosed sfPeerAddr

    -- * Logs

    logNewInputConnection addr =
        commLog . logDebug $
            sformat ("New input connection: "%int%" <- "%stext)
            port addr

    logErrorOnServerSocketProcessing jm addr e =
        logSeverityUnlessClosed Warning jm $
            sformat ("Error in server socket "%int%" connected with "%stext%": "%shown)
            port addr e

    logOnServerError jm e =
        logSeverityUnlessClosed Error jm $
            sformat ("Server at port "%int%" stopped with error "%shown) port e

    logInputConnHappilyClosed addr =
        commLog . logInfo $
            sformat ("Happily closing input connection "%int%" <- "%stext)
            port addr


-- | Listens for incoming bytes on outbound connection.
-- This thread doesn't block current thread. Use returned function to close relevant
-- connection.
listenOutbound :: NetworkAddress
               -> Sink BS.ByteString (ResponseT s (Transfer s)) ()
               -> Transfer s (Transfer s ())
listenOutbound addr sink = do
    conn <- getOutConnOrOpen addr
    outConnRec conn sink
    return $ stopAllJobs $ outConnJobCurator conn


getOutConnOrOpen :: NetworkAddress -> Transfer s (OutputConnection s)
getOutConnOrOpen addr@(host, fromIntegral -> port) =
    mask $
        \unmask -> do
            (conn, sfm) <- ensureConnExist
            forM_ sfm $
                \sf -> addSafeThreadJob (sfJobCurator sf) $
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
            us <- Transfer . lift . lift $ ask
            sf <- mkSocketFrame settings us addrName
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
        closed <- isInterrupted (sfJobCurator sf)
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
        interruptAllJobs (sfJobCurator sf) Plain
        modifyManager $ outputConn . at addr .= Nothing
        commLog . logDebug $
            sformat ("Socket to "%stext%" closed") addrName


instance MonadTransfer s (Transfer s) where
    sendRaw addr src = do
        conn <- getOutConnOrOpen addr
        outConnSend conn src

    listenRaw (AtPort   port) = listenInbound port
    listenRaw (AtConnTo addr) = listenOutbound addr

    -- closes asynchronuosly
    close addr = do
        maybeConn <- modifyManager . use $ outputConn . at addr
        forM_ maybeConn $
            \conn -> interruptAllJobs (outConnJobCurator conn) Plain

    userState addr =
        outConnUserState <$> getOutConnOrOpen addr


-- * Instances

instance MonadBaseControl IO (Transfer s) where
    type StM (Transfer s) a = StM (LoggerNameBox TimedIO) a
    liftBaseWith io =
        Transfer $ liftBaseWith $ \runInBase -> io $ runInBase . getTransfer
    restoreM = Transfer . restoreM
