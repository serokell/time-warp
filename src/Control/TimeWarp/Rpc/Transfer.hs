{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeSynonymInstances  #-}
{-# LANGUAGE UndecidableInstances  #-}

-- |
-- Module      : Control.TimeWarp.Rpc.Transfer
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC

module Control.TimeWarp.Rpc.Transfer
       ( Transfer (..)
       , runTransfer
       ) where

import qualified Control.Concurrent                 as C
import           Control.Concurrent.MVar            (MVar, modifyMVar, newEmptyMVar,
                                                     newMVar, putMVar, takeMVar)
import           Control.Concurrent.STM             (atomically)
import           Control.Concurrent.STM.TBMChan     (TBMChan, newTBMChanIO)
import           Control.Concurrent.STM.TVar        (TVar, newTVarIO, swapTVar)
import           Control.Lens                       (at, makeLenses, use, (.=), (<<+=),
                                                     (<<.=), (?=))
import           Control.Monad                      (forM_, void)
import           Control.Monad.Base                 (MonadBase)
import           Control.Monad.Catch                (MonadCatch, MonadMask,
                                                     MonadThrow (..), bracket_, handleAll)
import           Control.Monad.Reader               (ReaderT (..), ask)
import           Control.Monad.State                (StateT (..), runStateT)
import           Control.Monad.Trans                (MonadIO (..), lift)
import           Control.Monad.Trans.Control        (MonadBaseControl (..))
import           Data.ByteString                    (ByteString)
import qualified Data.ByteString                    as BS
import           Data.Conduit                       (Conduit, Producer, Source, ($$),
                                                     ($=))
import qualified Data.Conduit.List                  as CL
import           Data.Conduit.Network               (sinkSocket, sourceSocket)
import           Data.Conduit.TMChan                (sinkTBMChan, sourceTBMChan)
import qualified Data.Map                           as M
import           Data.Maybe                         (fromJust, isJust, isNothing)
import           Data.Streaming.Network             (getSocketFamilyTCP,
                                                     runTCPServerWithHandle,
                                                     serverSettingsTCP)
import           Data.Tuple                         (swap)
import           Formatting                         (sformat, shown, (%))
-- import           GHC.IO.Exception                   (IOException (IOError), ioe_errno)
import           Network.Socket                     as NS

import           Control.TimeWarp.Logging           (LoggerNameBox, WithNamedLogger,
                                                     logWarning)
import           Control.TimeWarp.Rpc.MonadTransfer (Binding (..), MonadTransfer (..),
                                                     NetworkAddress, Port,
                                                     ResponseContext (..), ResponseT,
                                                     runResponseT, runResponseT, sendRaw)
import           Control.TimeWarp.Timed             (MonadTimed, ThreadId, TimedIO, fork_)


-- * Realted datatypes

-- ** Connections

data OutputConnection = OutputConnection
    { outConnSend  :: Producer IO BS.ByteString -> IO ()
      -- | When someone starts listening, it should swap content with `Nothing`
    , outConnSrc   :: TVar (Maybe (Source IO BS.ByteString))
    , outConnClose :: IO ()
    }

data InputConnection = InputConnection
    { -- _inConnClose :: IO ()
    }
$(makeLenses ''InputConnection)

type InConnId = Int

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


-- * Transfer

newtype Transfer a = Transfer
    { getTransfer :: ReaderT (MVar Manager) (LoggerNameBox TimedIO) a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadBase IO,
                MonadThrow, MonadCatch, MonadMask, MonadTimed, WithNamedLogger)

type instance ThreadId Transfer = C.ThreadId

runTransfer :: Transfer a -> LoggerNameBox TimedIO a
runTransfer t = liftIO (newMVar initManager) >>= runReaderT (getTransfer t)

modifyManager :: StateT Manager IO a -> Transfer a
modifyManager how = Transfer $
    ask >>= liftIO . flip modifyMVar (fmap swap . runStateT how)


-- * Logic

listenInbound :: Port
              -> Conduit ByteString IO a
              -> (a -> ResponseT Transfer ())
              -> Transfer ()
listenInbound port condParser listener =
    liftBaseWith $
    \runInBase -> runTCPServerWithHandle (serverSettingsTCP port "*") $
        \sock _ _ -> void . runInBase $ do
            saveConn sock
            synchronously <- synchronizer
            let source = sourceSocket sock
                responseCtx =
                    ResponseContext
                    { respSend  = \src -> synchronously $ src $$ sinkSocket sock
                    , respClose = NS.close sock
                    }
            requestsChan <- startListener $ flip runResponseT responseCtx . listener
            logOnErr . liftIO $
                source $$ condParser $= sinkTBMChan requestsChan True
  where
    saveConn _ = do
        let conn =
                InputConnection
                { -- _inConnClose = NS.close sock
                }
        modifyManager $ do
            connId <- inputConnCounter <<+= 1
            inputConn . at connId .= Just conn

listenOutbound :: NetworkAddress
               -> Conduit ByteString IO a
               -> (a -> ResponseT Transfer ())
               -> Transfer ()
listenOutbound addr condParser listener = do
    conn <- getOutConnOrOpen addr
    maybeSource <- liftIO . atomically $ swapTVar (outConnSrc conn) Nothing
    let responseCtx =
            ResponseContext
            { respSend  = outConnSend conn
            , respClose = outConnClose conn
            }
    if isNothing maybeSource
        then error $ "Already listening at outbound connection to " ++ show addr
        else do
            let source = fromJust maybeSource
            requestsChan <- startListener $ flip runResponseT responseCtx . listener
            logOnErr . liftIO $
                source $$ condParser $= sinkTBMChan requestsChan True


instance MonadTransfer Transfer where
    sendRaw addr dat = do
        conn <- getOutConnOrOpen addr
        liftIO $ outConnSend conn dat

    listenRaw (AtPort   port) = listenInbound port
    listenRaw (AtConnTo addr) = listenOutbound addr

    close addr = do
        maybeWasConn <- modifyManager $ outputConn . at addr <<.= Nothing
        liftIO $ forM_ maybeWasConn outConnClose

logOnErr :: (WithNamedLogger m, MonadIO m, MonadCatch m) => m () -> m ()
logOnErr = handleAll $
    logWarning . sformat ("Server error: "%shown)

startListener :: (a -> Transfer ()) -> Transfer (TBMChan a)
startListener handler = do
    chan <- liftIO $ newTBMChanIO 1000
    fork_ $ sourceTBMChan chan $$ CL.mapM_ (fork_ . notifyOnError . handler)
    return chan
  where
    notifyOnError = handleAll $
        logWarning . sformat ("Uncaught exception in server handler: "%shown)

{-
splitToChans :: MonadIO m => TBMChan a -> TBMChan b -> Sink (Either a b) m ()
splitToChans ca cb =
    awaitForever $ \m ->
        case m of
            Left a  -> yield a $$ sinkTBMChan ca False
            Right b -> yield b $$ sinkTBMChan cb False
-}

synchronizer :: MonadIO m => m (IO () -> IO ())
synchronizer = do
    lock <- liftIO newEmptyMVar
    return $ \action ->
        bracket_ (putMVar lock ())
                 (takeMVar lock)
                 action

getOutConnOrOpen :: NetworkAddress -> Transfer OutputConnection
getOutConnOrOpen addr@(host, port) = do
    modifyManager $ do
        existing <- use $ outputConn . at addr
        if isJust existing
            then
                return $ fromJust existing
            else do
                -- TODO: use ResourceT
                (sock, _)     <- lift $ getSocketFamilyTCP host port NS.AF_UNSPEC
                source        <- lift . newTVarIO $ Just (sourceSocket sock)
                synchronously <- lift synchronizer
                let conn =
                       OutputConnection
                       { outConnSend  = \src -> synchronously $ src $$ sinkSocket sock
                       , outConnSrc   = source
                       , outConnClose = NS.close sock
                       }
                outputConn . at addr ?= conn
                return conn


-- * Instances

instance MonadBaseControl IO Transfer where
    type StM Transfer a = StM (ReaderT (MVar Manager) TimedIO) a
    liftBaseWith io =
        Transfer $ liftBaseWith $ \runInBase -> io $ runInBase . getTransfer
    restoreM = Transfer . restoreM
