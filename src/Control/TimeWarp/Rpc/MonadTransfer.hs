{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE UndecidableInstances      #-}

-- |
-- Module      : Control.TimeWarp.Rpc.MonadTransfer
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module defines monad, which serves to sending and receiving raw `ByteString`s.

module Control.TimeWarp.Rpc.MonadTransfer
       ( Port
       , Host
       , NetworkAddress
       , localhost

       , MonadTransfer (..)

       , MonadResponse (..)
       , ResponseContext (..)
       , ResponseT (..)
       , runResponseT
       , mapResponseT

       , RpcError (..)
       ) where

import           Control.Exception          (Exception)
import           Control.Monad.Catch        (MonadThrow, MonadCatch, MonadMask)
import           Control.Monad.Reader       (ReaderT (..), MonadReader (..), mapReaderT)
import           Control.Monad.State        (MonadState)
import           Control.Monad.Trans        (MonadTrans (..), MonadIO (..))
import           Data.Binary                (Get, Put)
import           Data.ByteString            (ByteString)
import           Data.Monoid                ((<>))
import           Data.Text                  (Text)
import           Data.Text.Buildable        (Buildable (..))

import           Control.TimeWarp.Logging   (LoggerNameBox (..), WithNamedLogger)
import           Control.TimeWarp.Timed     (MonadTimed, ThreadId)


-- * MonadTransfer

-- | Allows to send/receive raw byte sequences.
class Monad m => MonadTransfer m where
    -- | Sends raw data.
    sendRaw :: NetworkAddress  -- ^ Destination address
            -> Put             -- ^ Data to send
            -> m ()

    -- | Starts server with specified handler of incoming byte stream.
    listenRaw :: Port                    -- ^ Port to bind server
              -> Get a                   -- ^ Parser for input byte sequence
              -> (a -> ResponseT m ())   -- ^ Handler for received data
              -> m ()

    -- | Specifies incomings handler on outbound connection. Establishes connection
    -- if is doesn't exists.
    listenOutboundRaw :: NetworkAddress         -- ^ Where connection is opened to
                      -> Get a                  -- ^ Parser for input byte sequence
                      -> (a -> ResponseT m ())  -- ^ Handler for received data
                      -> m ()

    -- | Closes connection to specified node, if exists.
    close :: NetworkAddress -> m ()


-- * MonadResponse

-- | Provides operations related to /peer/ node. Peer is a node, which this node is
-- currently communicating with.
class Monad m => MonadResponse m where
    replyRaw :: Put -> m ()

    closeR :: m ()

data ResponseContext = ResponseContext
    { respSend  :: Put -> IO ()
    , respClose :: IO ()
    }

newtype ResponseT m a = ResponseT
    { getResponseT :: ReaderT ResponseContext m a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadTrans,
                MonadThrow, MonadCatch, MonadMask,
                MonadState s,
                WithNamedLogger, MonadTimed, MonadTransfer)

runResponseT :: ResponseT m a -> ResponseContext -> m a
runResponseT = runReaderT . getResponseT

type instance ThreadId (ResponseT m) = ThreadId m

instance MonadReader r m => MonadReader r (ResponseT m) where
    ask = lift ask
    reader f = lift $ reader f
    local = mapResponseT . local

instance (MonadTransfer m, MonadIO m) => MonadResponse (ResponseT m) where
    replyRaw dat = ResponseT $ ask >>= \ctx -> liftIO $ respSend ctx dat

    closeR = ResponseT $ ask >>= liftIO . respClose

mapResponseT :: (m a -> n b) -> ResponseT m a -> ResponseT n b
mapResponseT how = ResponseT . mapReaderT how . getResponseT

-- * Related datatypes

-- | Port number.
type Port = Int

-- | Host address.
type Host = ByteString

localhost :: Host
localhost = "127.0.0.1"

-- | Full node address.
type NetworkAddress = (Host, Port)


-- * Exceptions

-- | Exception which can be thrown on `send` call.
data RpcError = -- | Can't find remote method on server's side die to
                -- network problems or lack of such service
                NetworkProblem Text
                -- | Error in RPC protocol with description, or server
                -- threw unserializable error
              | InternalError Text

instance Buildable RpcError where
    build (NetworkProblem msg) = "Network problem: " <> build msg
    build (InternalError msg)  = "Internal error: " <> build msg

instance Show RpcError where
    show = show . build

instance Exception RpcError


-- * Instances

instance MonadTransfer m => MonadTransfer (ReaderT r m) where
    sendRaw addr req = lift $ sendRaw addr req

    listenRaw port parser listener =
        ReaderT $ \r -> listenRaw port parser $
                        mapResponseT (flip runReaderT r) . listener

    listenOutboundRaw addr parser listener =
        ReaderT $ \r -> listenOutboundRaw addr parser $
                        mapResponseT (flip runReaderT r) . listener

    close = lift . close

deriving instance MonadTransfer m => MonadTransfer (LoggerNameBox m)
