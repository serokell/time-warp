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
       , runTransfer
       ) where

import qualified Control.Concurrent                 as C
import           Control.Concurrent.MVar            (MVar, modifyMVar, newEmptyMVar,
                                                     newMVar, putMVar, takeMVar)
import           Control.Concurrent.STM             (atomically)
import           Control.Concurrent.STM.TVar        (TVar, newTVarIO, swapTVar)
import           Control.Lens                       (at, makeLenses, use, (.=), (<<+=),
                                                     (<<.=), (?=))
import           Control.Monad                      (forM_, void)
import           Control.Monad.Base                 (MonadBase)
import           Control.Monad.Catch                (MonadCatch, MonadMask,
                                                     MonadThrow (..), bracket_, handleAll)
import           Control.Monad.Morph                (hoist)
import           Control.Monad.Reader               (ReaderT (..), ask)
import           Control.Monad.State                (StateT (..), runStateT)
import           Control.Monad.Trans                (MonadIO (..), lift)
import           Control.Monad.Trans.Control        (MonadBaseControl (..))
import           Data.ByteString                    (ByteString)
import qualified Data.ByteString                    as BS
import           Data.Conduit                       (Producer, Sink, Source, ($$))
import           Data.Conduit.Network               (sinkSocket, sourceSocket)
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
                                                     logInfo, logWarning)
import           Control.TimeWarp.Rpc.MonadTransfer (Binding (..), MonadTransfer (..),
                                                     NetworkAddress, Port,
                                                     ResponseContext (..), ResponseT,
                                                     runResponseT, runResponseT, sendRaw)
import           Control.TimeWarp.Timed             (MonadTimed, ThreadId, TimedIO)


-- * Realted datatypes

-- ** Connections

data OutputConnection = OutputConnection
    { outConnSend  :: forall m . (MonadIO m, MonadMask m)
                   => Producer m BS.ByteString -> m ()
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
              -> Sink ByteString (ResponseT Transfer) ()
              -> Transfer ()
listenInbound (fromIntegral -> port) sink =
    liftBaseWith $
    \runInBase -> runTCPServerWithHandle (serverSettingsTCP port "*") $
        \sock _ _ -> void . runInBase $ do
            saveConn sock
            lock <- liftIO newEmptyMVar
            let source = sourceSocket sock
                responseCtx =
                    ResponseContext
                    { respSend  = \src -> synchronously lock $ src $$ sinkSocket sock
                    , respClose = NS.close sock
                    }
            logOnErr $ flip runResponseT responseCtx $
                hoist liftIO source $$ sink
            logInfo "Input connection closed"
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
               -> Sink ByteString (ResponseT Transfer) ()
               -> Transfer ()
listenOutbound addr sink = do
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
            logOnErr $ flip runResponseT responseCtx $
                hoist liftIO source $$ sink


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

synchronously :: (MonadIO m, MonadMask m) => MVar () -> m () -> m ()
synchronously lock action =
        bracket_ (liftIO $ putMVar lock ())
                 (liftIO $ takeMVar lock)
                 action

getOutConnOrOpen :: NetworkAddress -> Transfer OutputConnection
getOutConnOrOpen addr@(host, fromIntegral -> port) = do
    modifyManager $ do
        existing <- use $ outputConn . at addr
        if isJust existing
            then
                return $ fromJust existing
            else do
                -- TODO: use ResourceT
                (sock, _) <- lift $ getSocketFamilyTCP host port NS.AF_UNSPEC
                source    <- lift . newTVarIO $ Just (sourceSocket sock)
                lock      <- lift newEmptyMVar
                let conn =
                       OutputConnection
                       { outConnSend  = \src -> synchronously lock $
                                src $$ hoist liftIO (sinkSocket sock)
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
