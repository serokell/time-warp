{-# LANGUAGE BangPatterns          #-}
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

import           Control.Applicative                ((<|>))
import qualified Control.Concurrent                 as C
import           Control.Concurrent.MVar            (MVar, newEmptyMVar, newMVar,
                                                     takeMVar, putMVar, modifyMVar)
import           Control.Concurrent.STM             (atomically)
import           Control.Concurrent.STM.TVar        (TVar, newTVarIO, swapTVar)
import           Control.Lens                       (makeLenses, (<<.=), at,
                                                     (?=), use, (<<+=), (.=))
import           Control.Monad.Catch                (MonadCatch, MonadMask,
                                                     MonadThrow (..),
                                                     bracket)
import           Control.Monad                      (forM_, unless, void)
import           Control.Monad.Base                 (MonadBase)
import           Control.Monad.Reader               (ReaderT (..), ask)
import           Control.Monad.State                (runStateT, StateT (..))
import           Control.Monad.Trans                (MonadIO (..), lift)
import           Control.Monad.Trans.Control        (MonadBaseControl (..))
import           Data.Tuple                         (swap)
import qualified Data.Map                           as M
import           Data.Binary                        (Put, Get)
import           Data.Binary.Get                    (getWord8)
import           Data.Binary.Put                    (runPut)
import           Data.ByteString                    (ByteString)
import qualified Data.ByteString                    as BS
import           Data.ByteString.Lazy               (toStrict)
import           Data.Maybe                         (isJust, fromJust)
import           Data.Streaming.Network             (getSocketFamilyTCP,
                                                     runTCPServerWithHandle,
                                                     serverSettingsTCP, safeRecv)
-- import           GHC.IO.Exception                   (IOException (IOError), ioe_errno)
import           Network.Socket                     as NS
import           Network.Socket.ByteString          (sendAll)

import           Data.Conduit                       (($$+), ($$++), yield,
                                                     ResumableSource)
import           Data.Conduit.Serialization.Binary  (sinkGet)

import           Control.TimeWarp.Rpc.MonadTransfer (MonadTransfer (..), NetworkAddress,
                                                     runResponseT, sendRaw,
                                                     ResponseT, ResponseContext (..),
                                                     runResponseT)
import           Control.TimeWarp.Timed             (MonadTimed, TimedIO, ThreadId)


-- * Realted datatypes

-- ** Connections

data OutputConnection = OutputConnection
    { outConnSend  :: Put -> IO ()
      -- | When someone starts listening, it should swap content with `Nothing`
    , outConnSrc   :: TVar (Maybe (ResumableSource IO ByteString))
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
    { getTransfer :: ReaderT (MVar Manager) TimedIO a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadBase IO,
                MonadThrow, MonadCatch, MonadMask, MonadTimed)

type instance ThreadId Transfer = C.ThreadId

runTransfer :: Transfer a -> TimedIO a
runTransfer t = liftIO (newMVar initManager) >>= runReaderT (getTransfer t)

modifyManager :: StateT Manager IO a -> Transfer a
modifyManager how = Transfer $
    ask >>= liftIO . flip modifyMVar (fmap swap . runStateT how)


-- * Logic

instance MonadTransfer Transfer where
    sendRaw addr dat = do
        conn <- getOutConnOrOpen addr
        liftIO $ outConnSend conn dat

    listenRaw port parser listener =
        liftBaseWith $
        \runInBase -> runTCPServerWithHandle (serverSettingsTCP port "*") $
            \sock _ _ -> void . runInBase $ do
                src <- saveConn sock
                sender <- mkSender sock
                acceptRequests sender parser listener src
      where
        saveConn sock = do
            src <- socketSource sock
            let conn =
                    InputConnection
                    { -- _inConnClose = NS.sClose sock
                    }
            modifyManager $ do
                connId <- inputConnCounter <<+= 1
                inputConn . at connId .= Just conn
            return src

    listenOutboundRaw addr parser listener = do
        conn <- getOutConnOrOpen addr
        maybeOutConnSrc <- liftIO . atomically $ swapTVar (outConnSrc conn) Nothing
        maybe
            (error $ "Already listening at outbound connection to " ++ show addr)
            (acceptRequests (outConnSend conn) parser listener)
            maybeOutConnSrc

    close addr = do
        maybeWasConn <- modifyManager $ outputConn . at addr <<.= Nothing
        liftIO $ forM_ maybeWasConn outConnClose


acceptRequests :: (Put -> IO ())
               -> Get a
               -> (a -> ResponseT Transfer ())
               -> ResumableSource IO ByteString
               -> Transfer ()
acceptRequests sender parser listener src = do
    (src', rec) <- liftIO $ src $$++ sinkGet insistantParser
    runResponseT (listener rec) responseCtx
    acceptRequests sender parser listener src'
  where
    insistantParser = parser <|> (getWord8 >> insistantParser)
    responseCtx =
        ResponseContext
        { respSend  = sender
        , respClose = error "acceptRequests: respClose not implemented"
        }

getOutConnOrOpen :: NetworkAddress -> Transfer OutputConnection
getOutConnOrOpen addr@(host, port) = do
    modifyManager $ do
        existing <- use $ outputConn . at addr
        if isJust existing
            then
                return $ fromJust existing
            else do
                -- TODO: use ResourceT
                (sock, _)   <- lift $ getSocketFamilyTCP host port NS.AF_UNSPEC
                incomingSrc <- lift $ newTVarIO =<< Just <$> socketSource sock
                sender      <- lift $ mkSender sock
                let conn =
                       OutputConnection
                       { outConnSend = sender
                       , outConnSrc  = incomingSrc
                       , outConnClose = NS.close sock
                       }
                outputConn . at addr ?= conn
                return conn

mkSender :: MonadIO m => Socket -> m (Put -> IO ())
mkSender sock = liftIO $ do
    lock <- newEmptyMVar
    return $ sendData lock . toStrict . runPut
  where
    sendData :: MVar () -> ByteString -> IO ()
    sendData lock !bs =
        bracket
            (putMVar lock ())
            (const $ takeMVar lock)
            (const $ sendAll sock bs)

socketSource :: MonadIO m => Socket -> m (ResumableSource IO ByteString)
socketSource sock = liftIO $ fst <$> (source $$+ return ())
  where
    read' = safeRecv sock 4096
    source = do
        bs <- liftIO read'
        unless (BS.null bs) $ do
            yield bs
            source


-- * Instances

instance MonadBaseControl IO Transfer where
    type StM Transfer a = StM (ReaderT (MVar Manager) TimedIO) a
    liftBaseWith io =
        Transfer $ liftBaseWith $ \runInBase -> io $ runInBase . getTransfer
    restoreM = Transfer . restoreM
