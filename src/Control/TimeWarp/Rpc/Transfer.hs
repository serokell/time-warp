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
       ) where

import qualified Control.Concurrent                 as C
import           Control.Concurrent.MVar            (MVar, modifyMVar, newEmptyMVar,
                                                     newMVar, putMVar, takeMVar)
import           Control.Concurrent.STM             (atomically, check)
import qualified Control.Concurrent.STM.TBMChan     as TBM
import           Control.Concurrent.STM.TChan       as TC
import           Control.Concurrent.STM.TVar        as TV
import           Control.Lens                       (at, each, makeLenses, use, view,
                                                     (.=), (<<+=), (?=), (^..))
import           Control.Monad                      (forM_, forever, guard, unless, when)
import           Control.Monad.Base                 (MonadBase)
import           Control.Monad.Catch                (Exception, MonadCatch, MonadMask,
                                                     MonadThrow (..), bracket,
                                                     bracketOnError, catchAll, finally,
                                                     handleAll, mask, throwM)
import           Control.Monad.Morph                (hoist)
import           Control.Monad.Reader               (ReaderT (..), ask)
import           Control.Monad.State                (StateT (..), runStateT)
import           Control.Monad.Trans                (MonadIO (..), lift)
import           Control.Monad.Trans.Control        (MonadBaseControl (..))
import qualified Data.ByteString                    as BS
import qualified Data.ByteString.Lazy               as BL
import           Data.Conduit                       (Sink, Source, awaitForever, ($$),
                                                     (=$=))
import           Data.Conduit.Binary                (sinkLbs, sourceLbs)
import           Data.Conduit.Network               (sinkSocket, sourceSocket)
import           Data.Conduit.TMChan                (sinkTBMChan, sourceTBMChan)
import qualified Data.IORef                         as IR
import           Data.List                          (intersperse)
import qualified Data.Map                           as M
import           Data.Maybe                         (fromJust, isJust)
import           Data.Streaming.Network             (acceptSafe, bindPortTCP,
                                                     getSocketFamilyTCP)
import           Data.Conduit.List                  (iterM)
import           Data.Text                          (Text)
import           Data.Text.Buildable                (Buildable (build), build)
import           Data.Text.Encoding                 (decodeUtf8)
import           Data.Tuple                         (swap)
import           Data.Typeable                      (Typeable)
import           Formatting                         (bprint, builder, int, sformat, shown,
                                                     stext, string, (%))
-- import           GHC.IO.Exception                   (IOException (IOError), ioe_errno)
import           Network.Socket                     as NS

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
                                                     killThread, sec, wait)


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


-- ** Connections

-- | Textual representation of peer node. For debugging purposes only.
type PeerAddr = Text

data OutputConnection = OutputConnection
    { outConnSend     :: forall m . (MonadIO m, MonadMask m, WithNamedLogger m)
                      => Source m BS.ByteString -> m ()
      -- ^ Keeps function to send to socket
    , outConnRec      :: forall m . (MonadIO m, MonadMask m, MonadTimed m,
                                     WithNamedLogger m)
                      => Sink BS.ByteString (ResponseT m) () -> m (IO ())
      -- ^ Keeps listener sink, if free
    , outConnClose    :: IO ()
      -- ^ Closes socket as soon as all messages send, prevent any further manupulations
      -- with message queues
    , outConnAddr     :: PeerAddr
      -- ^ Address of socket on other side of net
    }

data InputConnection = InputConnection
    { -- _inConnClose :: IO ()
    }
$(makeLenses ''InputConnection)

type InConnId = Int


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
    { _inputConn        :: M.Map InConnId InputConnection
    , _outputConn       :: M.Map NetworkAddress OutputConnection
    , _inputConnCounter :: InConnId
    }
$(makeLenses ''Manager)

initManager :: Manager
initManager =
    Manager
    { _inputConn = M.empty
    , _inputConnCounter = 0
    , _outputConn = M.empty
    }


-- ** SocketFrame

-- | Keeps data which helps to improve socket to smart socket.
data SocketFrame = SocketFrame
    { sfPeerAddr  :: PeerAddr
    -- ^ Peer address, for debuging purposes only
    , sfInBusy    :: TV.TVar Bool
    -- ^ Whether someone already listens on this socket
    , sfInChan    :: TBM.TBMChan BS.ByteString
    -- ^ For incoming packs of bytes
    , sfOutChan   :: TBM.TBMChan BL.ByteString
     -- ^ For packs of bytes to send
    , sfIsClosed  :: TV.TVar Bool
    -- ^ Whether @close@ hhas been invoked
    , sfIsClosedF :: TV.TVar Bool
    -- ^ Whether socket is really closed and resources released
    }

mkSocketFrame :: MonadIO m => Settings -> PeerAddr -> m SocketFrame
mkSocketFrame settings sfPeerAddr = liftIO $ do
    sfInBusy    <- TV.newTVarIO False
    sfInChan    <- TBM.newTBMChanIO (_queueSize settings)
    sfOutChan   <- TBM.newTBMChanIO (_queueSize settings)
    sfIsClosed  <- TV.newTVarIO False
    sfIsClosedF <- TV.newTVarIO False
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
    liftIO . atomically . TBM.writeTBMChan sfOutChan $ lbs
  where
    whenM condM action = condM >>= flip when action

-- | Constructs function which allows infinitelly listens on given `SocketFrame` in terms of
-- `MonadTransfer`.
-- Attempt to use this function twice will end with `AlreadyListeningOutbound` error.
sfReceive :: (MonadIO m, MonadMask m, MonadTimed m, WithNamedLogger m)
          => SocketFrame ->  Sink BS.ByteString (ResponseT m) () -> m (IO ())
sfReceive sf@SocketFrame{..} sink = do
    busy <- liftIO . atomically $ TV.swapTVar sfInBusy True
    when busy $ throwM $ AlreadyListeningOutbound sfPeerAddr

    liClosed <- liftIO $ TV.newTVarIO False
    ltid <- fork $ logOnErr $  -- TODO: disconnect / reconnect on error?
        flip finally (liftIO . atomically $ writeTVar liClosed True) $ do
            flip runResponseT (sfResponseCtx sf) $
                sourceTBMChan sfInChan $$ sink
            commLog . logDebug $ sformat ("Listening on socket to "%shown%
                                          " happily stopped") sfPeerAddr

    fork_ $ do
        liftIO . atomically $ check =<< readTVar sfIsClosed
        wait (for 3 sec)
        c <- liftIO . atomically $ TV.readTVar liClosed
        unless c $ do
            commLog . logDebug $
                sformat ("While closing socket to "%shown%" listener "%
                         "worked for too long, closing with no regard to it") sfPeerAddr
            killThread ltid
            liftIO . atomically $ writeTVar liClosed True
    return $ do
        sfClose sf
        atomically $ check =<< ((&&) <$> readTVar sfIsClosedF <*> readTVar liClosed)

sfClose :: (MonadIO m) => SocketFrame -> m ()
sfClose SocketFrame{..} = liftIO . atomically $ do
    writeTVar sfIsClosed True
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
        liftIO . atomically $ check =<< TV.readTVar sfIsClosed
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
        commLog . logDebug $ sformat ("Init foreverSend to "%stext) sfPeerAddr
        finally (sourceTBMChan sfOutChan =$= noteSend =$= awaitForever sourceLbs $$ sinkSocket sock) (commLog . logDebug $ sformat ("Quit foreverSend for "%stext) sfPeerAddr)

    foreverRec = do
        hoist liftIO (sourceSocket sock) =$= noteRec $$ sinkTBMChan sfInChan False
        isClosed <- liftIO $ readTVarIO sfIsClosed
        unless isClosed $
            throwM PeerClosedConnection

    noteSend = iterM $ const $
        commLog . logDebug $
            sformat ("-> "%stext%" +1 message") sfPeerAddr

    noteRec = iterM $ const $
        commLog . logDebug $
            sformat ("<- "%stext%" +1 message") sfPeerAddr

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
              -> Transfer (IO ())
listenInbound (fromIntegral -> port) sink = do
    -- whether `close` was invoked
    isClosed  <- liftIO . atomically $ TV.newTVar False
    let unlessClosed act = liftIO (TV.readTVarIO isClosed) >>= flip unless act
    -- stoppers
    -- TODO: remove stoppers / awaiters when they are not more needed
    stoppers  <- liftIO . atomically $ newTVar []
    let addStopper s = liftIO . atomically $ modifyTVar' stoppers (s:)
    -- waiters till resources cleaned
    awaiters  <- liftIO . atomically $ TV.newTVar []
    let addAwaiter = liftIO . atomically $ do
            t <- newTVar False
            modifyTVar' awaiters $ (:) $ liftIO . atomically $ check =<< readTVar t
            return $ atomically $ writeTVar t True

    -- launch server
    bracketOnError (liftIO $ bindPortTCP port "*") (liftIO . NS.close) $
        \lsocket -> mask $ \unmask -> do
            markReady <- liftIO <$> addAwaiter
            sid <- fork . flip finally (liftIO $ NS.close lsocket) . unmask $
                logOnServeErr unlessClosed $
                    serve lsocket unlessClosed addStopper addAwaiter `finally` markReady
            addStopper =<< actionToIO (killThread sid)

    -- closer
    logClose  <- actionToIO $ commLog . logDebug $
        sformat ("Stopping server at "%int) port
    logClosed <- actionToIO $ commLog . logDebug $
        sformat ("Server at "%int%" fully stopped") port
    return $ do
        liftIO . atomically $ TV.writeTVar isClosed True
        logClose
        sequence_ =<< TV.readTVarIO stoppers
        sequence_ =<< TV.readTVarIO awaiters
        logClosed
  where
    saveConn _ = do
        let conn =
                InputConnection
                { -- _inConnClose = NS.close sock
                }
        modifyManager $ do
            connId <- inputConnCounter <<+= 1
            inputConn . at connId .= Just conn

    serve lsocket unlessClosed addStopper addAwaiter = forever $
        bracketOnError (liftIO $ acceptSafe lsocket) (liftIO . NS.close . fst) $
            \(sock, addr) -> mask $
                \unmask -> fork_ $ do
                    markReady <- addAwaiter
                    unmask (processSocket sock addr unlessClosed addStopper)
                            `finally` liftIO (NS.close sock >> markReady)

    logOnServeErr unlessClosed = handleAll $ \e -> do
            unlessClosed . logError $ sformat ("Server at port "%int%" stopped with error "%shown) port e
            logDebug $ sformat ("Server at port "%int%" stopped with error "%shown) port e

    -- makes socket work, finishes once it's fully shutdown
    processSocket sock peerAddr unlessClosed addStopper = do
        liftIO $ NS.setSocketOption sock NS.ReuseAddr 1
        saveConn sock

        settings <- Transfer ask
        sf <- mkSocketFrame settings $ buildSockAddr peerAddr
        commLog . logDebug $
            sformat ("New input connection: "%int%" <- "%stext)
            port (sfPeerAddr sf)

       -- start listener, which works in another thread
        stopper <- sfReceive sf sink
        addStopper =<< actionToIO (liftIO stopper)
        -- start `SocketFrame`'s' workers
        unlessClosed $ startProcessing sf unlessClosed $ do
            sfProcessSocket sf sock
            commLog . logInfo $
                sformat ("Happily closing input connection "%int%" <- "%stext)
                port (sfPeerAddr sf)

        -- here socket processing stopped, release resources
        liftIO . atomically $ writeTVar (sfIsClosedF sf) True
        liftIO stopper

    startProcessing sf unlessClosed action =
        action `catchAll` \e -> do
          unlessClosed . commLog . logWarning $
            sformat ("Error in server socket "%int%" connected with "%stext%": "%shown)
                port (sfPeerAddr sf) e
          commLog . logDebug $
            sformat ("Error in server socket "%int%" connected with "%stext%": "%shown)
                port (sfPeerAddr sf) e

-- Here is hack to use @IO ()@ as closer, not @m ()@, for now. TODO: remove
actionToIO :: (MonadIO m, MonadTimed m) => m () -> m (IO ())
actionToIO a = do
    m <- liftIO newEmptyMVar
    fork_ $ liftIO (takeMVar m) >> a
    return $ putMVar m ()

-- | Listens for incoming bytes on outbound connection.
-- Listening would occur until sink gets closed. Killing this thread won't help here.
-- Attempt to listen on socket which is already being listened causes exception.
-- Subscribtions could be implemented at layer above, where we operate with messages.
listenOutbound :: NetworkAddress
               -> Sink BS.ByteString (ResponseT Transfer) ()
               -> Transfer (IO ())
listenOutbound addr sink = do
    conn <- getOutConnOrOpen addr
    outConnRec conn sink

logOnErr :: (WithNamedLogger m, MonadIO m, MonadCatch m) => m () -> m ()
logOnErr = handleAll $ \e ->
    commLog . logDebug $ sformat ("Server !! error: "%shown) e


getOutConnOrOpen :: NetworkAddress -> Transfer OutputConnection
getOutConnOrOpen addr@(host, fromIntegral -> port) = do
    -- TODO: care about async exceptions
    (conn, sfm) <- ensureConnExist
    forM_ sfm $
        \sf -> fork_ $
            startWorker sf `finally` releaseConn sf
    return conn
  where
    ensureConnExist = do
        settings <- Transfer ask
        modifyManager $ do
            existing <- use $ outputConn . at addr
            if isJust existing
                then
                    return (fromJust existing, Nothing)
                else do
                    sf <- mkSocketFrame settings $ buildNetworkAddress addr
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
        closed <- liftIO . atomically $ readTVar (sfIsClosed sf)
        unless closed $ do
            commLog . logWarning $
                sformat ("Error while working with socket to "%shown%": "%shown) addr e

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

    releaseConn sf = do
        modifyManager $ outputConn . at addr .= Nothing
        liftIO . atomically $ TV.writeTVar (sfIsClosedF sf) True
        commLog . logDebug $
            sformat ("Socket to "%shown%" closed") addr


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
