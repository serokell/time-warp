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
-- Module      : Control.TimeWarp.MonadTransfer
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
       , Variant (..)
       
       , MonadResponse (..)
       , ResponseT (..)
       , mapResponseT
       , replyRaw
       , closePeer

       , RpcError (..)
       ) where

import           Control.Exception          (Exception)
import           Control.Monad.Catch        (MonadThrow, MonadCatch, MonadMask)
import           Control.Monad.Reader       (ReaderT (..), MonadReader (..), mapReaderT)
import           Control.Monad.State        (MonadState)
import           Control.Monad.Trans        (MonadTrans (..), MonadIO)
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
    sendRaw :: NetworkAddress  -- ^ Receiver's address
            -> Put             -- ^ Data to send
            -> m ()

    -- | Starts server.
    -- If parsing failed, protocol attempts to parse input starting from next character;
    -- consider checking for /magic/ sequence first while parsing.
    listenRaw :: Port                      -- ^ Port to bind server
              -> [Variant m]               -- ^ Cases of input data
              -> m ()

    -- | Closes connection to specified node, if exists.
    close :: NetworkAddress -> m ()

-- | Specifies case of input data and according action to process this data.
data Variant m =
    forall a . Variant (Get a) (a -> ResponseT m ())


-- * MonadResponse

-- | Provides operations with /peer/ node. Peer is a node, which this node is
-- currently communicating with.
class Monad m => MonadResponse m where
    peerAddr :: m NetworkAddress

newtype ResponseT m a = ResponseT
    { runResponseT :: ReaderT NetworkAddress m a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadTrans,
                MonadThrow, MonadCatch, MonadMask,
                MonadState s,
                WithNamedLogger, MonadTimed, MonadTransfer)

type instance ThreadId (ResponseT m) = ThreadId m

instance MonadTransfer m => MonadResponse (ResponseT m) where
    peerAddr = ResponseT ask

instance MonadReader r m => MonadReader r (ResponseT m) where
    ask = lift ask
    reader f = lift $ reader f
    local = mapResponseT . local

mapResponseT :: (m a -> n b) -> ResponseT m a -> ResponseT n b
mapResponseT how = ResponseT . mapReaderT how . runResponseT

-- | Sends data to /peer/ node.
replyRaw :: (MonadTransfer m, MonadResponse m) => Put -> m ()
replyRaw s = peerAddr >>= flip sendRaw s

-- | Closes connection with /peer/ node.
closePeer :: (MonadTransfer m, MonadResponse m) => m ()
closePeer = peerAddr >>= close

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

    listenRaw port vars =
        ReaderT $ \r -> listenRaw port $ convert r <$> vars
      where
        convert r (Variant a f) = Variant a $ mapResponseT (flip runReaderT r) . f

    close = lift . close

deriving instance MonadTransfer m => MonadTransfer (LoggerNameBox m)

