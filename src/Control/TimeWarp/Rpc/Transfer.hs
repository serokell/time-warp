{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}
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
       , exampleTransfer
       ) where

import           Control.Applicative                ((<|>))
import qualified Control.Concurrent                 as C
import           Control.Concurrent.MVar            (MVar, newEmptyMVar, newMVar,
                                                     takeMVar, putMVar, modifyMVar)
import           Control.Lens                       (makeLenses, (<<.=), at,
                                                     (?=), use, (<<+=),
                                                     _Just, (.=), zoom, singular)
import           Control.Monad.Catch                (MonadCatch, MonadMask,
                                                     MonadThrow (..),
                                                     bracket)
import           Control.Monad                      (forM_, unless, void, guard)
import           Control.Monad.Base                 (MonadBase)
import           Control.Monad.Reader               (ReaderT (..), ask)
import           Control.Monad.State                (runStateT, StateT (..))
import           Control.Monad.Trans                (MonadIO (..), lift)
import           Control.Monad.Trans.Control        (MonadBaseControl (..))
import           Control.Monad.Trans.Maybe          (MaybeT, runMaybeT)
import           Data.Tuple                         (swap)
import           Data.Maybe                         (isJust, fromJust)
import qualified Data.Map                           as M
import           Data.Binary                        (Put, Get, get, put)
import           Data.Binary.Get                    (getWord8)
import           Data.Binary.Put                    (runPut)
import           Data.ByteString                    (ByteString)
import qualified Data.ByteString                    as BS
import           Data.ByteString.Lazy               (toStrict)
import           Data.Streaming.Network             (getSocketFamilyTCP,
                                                     runTCPServerWithHandle,
                                                     serverSettingsTCP, safeRecv)
-- import           GHC.IO.Exception                   (IOException (IOError), ioe_errno)
import           Network.Socket                     as NS
import           Network.Socket.ByteString          (sendAll)

import           Data.Conduit                       (($$+), ($$++), yield, Producer,
                                                     ResumableSource)
import           Data.Conduit.Serialization.Binary  (sinkGet)

import           Control.TimeWarp.Rpc.MonadTransfer (MonadTransfer (..), NetworkAddress,
                                                     runResponseT)
import           Control.TimeWarp.Timed             (MonadTimed, TimedIO, ThreadId,
                                                     runTimedIO, wait, for, ms,
                                                     schedule, after, work)

-- * Realted datatypes

-- ** Connections

data OutputConnection = OutputConnection
    { outConnSend    :: Put -> IO ()
    , outConnClose   :: IO ()
    }

data InputConnection = InputConnection
    { -- _inConnClose :: IO ()
      _inConnSrc   :: ResumableSource IO ByteString
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

runTransfer :: Transfer a -> IO a
runTransfer t = do
    m <- newMVar initManager
    runTimedIO $ runReaderT (getTransfer t) m

modifyManager :: StateT Manager IO a -> Transfer a
modifyManager how = Transfer $
    ask >>= liftIO . flip modifyMVar (fmap swap . runStateT how)

-- * Logic

getOutConnOrOpen :: NetworkAddress -> Transfer OutputConnection
getOutConnOrOpen addr@(host, port) =
    modifyManager $ do
        existing <- use $ outputConn . at addr
        if isJust existing
            then
                return $ fromJust existing
            else do
                lock <- lift newEmptyMVar
                -- TODO: use ResourceT
                (sock, _) <- lift $ getSocketFamilyTCP host port NS.AF_UNSPEC
                let conn =
                       OutputConnection
                       { outConnSend = sendData sock lock . toStrict . runPut
                       , outConnClose = NS.sClose sock
                       }
                outputConn . at addr ?= conn
                return conn
      where
        sendData :: NS.Socket -> MVar () -> ByteString -> IO ()
        sendData sock lock !bs =
            bracket
                (putMVar lock ())
                (const $ takeMVar lock)
                (const $ sendAll sock bs)



instance MonadTransfer Transfer where
    sendRaw addr dat = do
        conn <- getOutConnOrOpen addr
        liftIO $ outConnSend conn dat

    listenRaw port parser listener =
        liftBaseWith $
        \runInBase -> runTCPServerWithHandle (serverSettingsTCP port "*") $
            \sock _ _ -> void . runInBase $
                saveConn sock >>= runMaybeT . acceptRequests
      where
        saveConn sock = do
            (src, _) <- liftIO $ socketSource sock $$+ return ()
            let conn =
                    InputConnection
                    { -- _inConnClose = NS.sClose sock
                      _inConnSrc = src
                    }
            connId <- modifyManager $ do
                connId <- inputConnCounter <<+= 1
                inputConn . at connId .= Just conn
                return connId
            return connId

        acceptRequests :: InConnId -> MaybeT Transfer ()
        acceptRequests connId = do
            Just recData <- lift . modifyManager $ do
                    maybeConn <- use $ inputConn . at connId
                    if isJust maybeConn
                        then Just <$> extractRequest connId insistantParser
                        else return Nothing

            lift $ flip runReaderT (error "Don't touch MonadResponse for now")
                 $ runResponseT
                 $ listener $ recData
            acceptRequests connId

        extractRequest connId p =
            zoom
                (singular $ inputConn . at connId . _Just . inConnSrc) $
                StateT $
                    \src -> swap <$> (src $$++ sinkGet p)

        insistantParser = parser <|> (getWord8 >> insistantParser)

    close addr =
        modifyManager $ do
            maybeWas <- outputConn . at addr <<.= Nothing
            lift $ forM_ maybeWas outConnClose

socketSource :: MonadIO m => Socket -> Producer m ByteString
socketSource sock = loop
  where
    read' = safeRecv sock 4096
    loop = do
        bs <- liftIO read'
        unless (BS.null bs) $ do
            yield bs
            loop

-- * Instances

type instance ThreadId Transfer = C.ThreadId

instance MonadBaseControl IO Transfer where
    type StM Transfer a = StM (ReaderT (MVar Manager) TimedIO) a
    liftBaseWith io =
        Transfer $ liftBaseWith $ \runInBase -> io $ runInBase . getTransfer
    restoreM = Transfer . restoreM


-- * Example

exampleTransfer :: Transfer ()
exampleTransfer = do
    work (for 500 ms) $
        listenRaw 1234 parser $ liftIO . print
    
    wait (for 100 ms)

    schedule (after 200 ms) $
        forM_ [1..7] $ sendRaw ("127.0.0.1", 1234) . (put bad >> ) . writer . Left

    schedule (after 200 ms) $
        forM_ [1..5] $ sendRaw ("127.0.0.1", 1234) . writer . Right . (-1, )

  where
    parser :: Get (Either Int (Int, Int))
    parser = do
        magic <- get
        guard $ magic == (234 :: Int)
        get

    writer :: Either Int (Int, Int) -> Put
    writer d = put (234 :: Int) >> put d

    bad :: String
    bad = "345"
