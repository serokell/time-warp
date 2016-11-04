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
import           Control.Monad                      (forM_, forever, replicateM_, unless,
                                                     void, when)
import           Control.Monad.Base                 (MonadBase (..))
import           Control.Monad.Catch                (Exception, MonadCatch, MonadMask,
                                                     MonadThrow (..), bracket, bracket_,
                                                     catchAll, finally, handleAll, throwM)
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
import           Data.List                          (intersperse)
import qualified Data.Map                           as M
import           Data.Maybe                         (fromJust, isJust)
import           Data.Streaming.Network             (getSocketFamilyTCP,
                                                     runTCPServerWithHandle,
                                                     serverSettingsTCP)
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


data TransferException = AlreadyListeningOutbound Text
    deriving (Show, Typeable)

instance Exception TransferException

instance Buildable TransferException where
    build (AlreadyListeningOutbound addr) =
        bprint ("Already listening at outbound connection to "%stext) addr

-- * Related datatypes

-- ** Connections

-- | Textual representation of peer node. For debugging purposes only.
type PeerAddr = Text

data OutputConnection = OutputConnection
    { outConnSend     :: forall m . (MonadIO m, MonadMask m)
                      => Source m BS.ByteString -> m ()
      -- ^ Keeps function to send to socket
    , outConnRec      :: forall m . (MonadIO m, MonadCatch m, MonadTimed m,
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

data Settings = Settings
    { _queueSize       :: Int
    , _reconnectPolicy :: forall m . (WithNamedLogger m, MonadIO m)
                       => m (Maybe Microsecond)
    }
$(makeLenses ''Settings)

-- | Default settings, you can use it like @transferSettings { _queueSize = 1 }@
transferSettings :: Settings
transferSettings = Settings
    { _queueSize = 100
    , _reconnectPolicy = return (Just $ interval 3 sec)
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
sfSender :: MonadIO m
         => SocketFrame -> Source m BS.ByteString -> m ()
sfSender SocketFrame{..} src = do
    lbs <- src $$ sinkLbs
    liftIO . atomically . TBM.writeTBMChan sfOutChan $ lbs

-- | Constructs function which allows infinitelly listens on given `SocketFrame` in terms of
-- `MonadTransfer`.
-- Attempt to use this function twice will end with `AlreadyListeningOutbound` error.
sfReceiver :: (MonadIO m, MonadCatch m, MonadTimed m, WithNamedLogger m)
           => SocketFrame ->  Sink BS.ByteString (ResponseT m) () -> m (IO ())
sfReceiver sf@SocketFrame{..} sink = do
    busy <- liftIO . atomically $ TV.swapTVar sfInBusy True
    when busy $ throwM $ AlreadyListeningOutbound sfPeerAddr
    fork_ $ logOnErr $
        flip runResponseT (sfResponseCtx sf) $
            sourceTBMChan sfInChan $$ sink
    return $ do
        sfClose sf
        atomically $ check =<< readTVar sfIsClosedF

sfClose :: MonadIO m => SocketFrame -> m ()
sfClose SocketFrame{..} = liftIO . atomically $ do
    writeTVar sfIsClosed True
    TBM.closeTBMChan sfInChan
    TBM.closeTBMChan sfOutChan

sfOutputConn :: SocketFrame -> OutputConnection
sfOutputConn sf =
    OutputConnection
    { outConnSend  = sfSender sf
    , outConnRec   = sfReceiver sf
    , outConnClose = sfClose sf
    , outConnAddr  = sfPeerAddr sf
    }

sfResponseCtx :: SocketFrame -> ResponseContext
sfResponseCtx sf =
    ResponseContext
    { respSend     = sfSender sf
    , respClose    = sfClose sf
    , respPeerAddr = sfPeerAddr sf
    }

-- | Starts workers, which connect channels in `SocketFrame` with real `NS.Socket`.
-- If error in any worker occured, it's propagaded.
sfProcessSocket :: (MonadIO m, MonadCatch m, MonadTimed m)
                => SocketFrame -> NS.Socket -> m ()
sfProcessSocket sf@SocketFrame{..} sock = do
    -- TODO: rewrite to async when MonadTimed supports it
    -- create channel to notify about error
    eventChan  <- liftIO TC.newTChanIO
    -- create worker threads
    stid <- fork $ reportExecution eventChan foreverSend
    rtid <- fork $ reportExecution eventChan foreverRec
    -- check whether @isClosed@ keeps @True@
    ctid <- fork $ do
        liftIO . atomically $ check =<< TV.readTVar sfIsClosed
        replicateM_ 2 . liftIO . atomically $
            TC.writeTChan eventChan $ Right ()
        mapM_ killThread [stid, rtid]
    -- wait for error messages
    let onError e = do
            mapM_ killThread [stid, rtid, ctid]
            throwM e
    replicateM_ 2 $ do
        event <- liftIO . atomically $ TC.readTChan eventChan
        either onError return event
    -- at this point channels are closed
  where
    foreverSend =
        sourceTBMChan sfOutChan =$= awaitForever sourceLbs $$ sinkSocket sock

    foreverRec =
        forever $
            flip runResponseT (sfResponseCtx sf) $
                hoist liftIO (sourceSocket sock) $$ sinkTBMChan sfInChan False

    reportExecution eventChan action = do
        catchAll action $ liftIO . atomically . TC.writeTChan eventChan . Left
        liftIO . atomically . TC.writeTChan eventChan $ Right ()


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
               -- ^ TODO: what is this?

buildNetworkAddress :: NetworkAddress -> PeerAddr
buildNetworkAddress (host, port) = sformat (stext%":"%int) (decodeUtf8 host) port

listenInbound :: Port
              -> Sink BS.ByteString (ResponseT Transfer) ()
              -> Transfer (IO ())
listenInbound (fromIntegral -> port) sink = do
    isClosed <- liftIO . atomically $ TV.newTVar False
    stid <- startServer isClosed $ liftBaseWith $
        -- TODO rewrite `runTCPServerWithHandle` to separate `bind` and `listen`
        -- bind should fail in thread, which launches server (not spawned one)
        \runInBase -> runTCPServerWithHandle (serverSettingsTCP port "*") $
            \sock peerAddr _ -> void . runInBase $ do
                liftIO $ NS.setSocketOption sock NS.ReuseAddr 1
                saveConn sock
                let peerName = buildSockAddr peerAddr
                lock <- liftIO newEmptyMVar
                let source = sourceSocket sock
                    responseCtx =
                        ResponseContext
                        { respSend     = \src -> synchronously lock $
                                              -- ^ TODO: eliminate
                                            src $$ sinkSocket sock
                        , respClose    = NS.close sock
                        , respPeerAddr = peerName
                        }

                logOnErr $ flip runResponseT responseCtx $
                    hoist liftIO source $$ sink
                commLog . logInfo $
                    sformat ("Input connection from "%stext%" closed") peerName
    -- hack to use @IO ()@ as closer, not @m ()@, for now.
    m <- liftIO newEmptyMVar
    fork_ $ liftIO (takeMVar m) >> killThread stid
    return $ do
        putMVar m ()
        atomically $ check =<< TV.readTVar isClosed
  where
    saveConn _ = do
        let conn =
                InputConnection
                { -- _inConnClose = NS.close sock
                }
        modifyManager $ do
            connId <- inputConnCounter <<+= 1
            inputConn . at connId .= Just conn
    startServer isClosed action =
        fork $ action
                `catchAll` (logError . sformat ("Server at port " % int % " stopped with error " % shown) port)
                `finally` (liftIO . atomically $ TV.writeTVar isClosed True)

synchronously :: (MonadIO m, MonadMask m) => MVar () -> m () -> m ()
synchronously lock =
        bracket_ (liftIO $ putMVar lock ())
                 (liftIO $ takeMVar lock)


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
    commLog . logDebug $ sformat ("Server error: "%shown) e


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

    startWorker sf =
        withRecovery sf $
            bracket (liftIO $ fst <$> getSocketFamilyTCP host port NS.AF_UNSPEC)
                    (liftIO . NS.close) $
                    sfProcessSocket sf

    withRecovery sf action = catchAll action $ \e -> do
        closed <- liftIO . atomically $ readTVar (sfIsClosed sf)
        unless closed $ do
            commLog . logWarning $
                sformat ("Error while working with socket to "%shown%": "%shown) addr e
            reconnect <- Transfer $ view reconnectPolicy
            maybeReconnect <- reconnect
            case maybeReconnect of
                Nothing -> do
                    commLog . logWarning $
                        sformat ("Reconnection policy = don't reconnect "%shown%
                                 ", closing connection") addr
                    throwM e
                Just delay -> do
                    commLog . logWarning $
                        sformat ("Reconnect in "%shown) delay
                    wait (for delay)
                    withRecovery sf action

    releaseConn sf = do
        modifyManager $ outputConn . at addr .= Nothing
        liftIO . atomically $ TV.writeTVar (sfIsClosedF sf) True
        commLog . logDebug $
            sformat ("Socket to "%shown%" closed") addr


instance MonadTransfer Transfer where
    sendRaw addr src = do
        conn <- getOutConnOrOpen addr
        liftIO $ outConnSend conn src

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
