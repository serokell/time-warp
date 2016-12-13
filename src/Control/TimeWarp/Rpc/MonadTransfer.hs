{-# LANGUAGE AllowAmbiguousTypes       #-}
{-# LANGUAGE DefaultSignatures         #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE FunctionalDependencies    #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE UndecidableInstances      #-}

-- |
-- Module      : Control.TimeWarp.Rpc.MonadTransfer
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Serokell <hi@serokell.io>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module defines monad, which serves for sending and receiving raw byte streams.
--
-- UPGRAGE-NOTE (TW-47):
-- We'd like to have another interface for `listenRaw` function.
-- Currently it allows only single listener for given connection.
-- It makes difficult to define, for example, a listener for all outbound connections,
-- which is likely to have.
-- There is a proposal to have subscriptions-based interface:
--
--   * `listenRaw` is in some sense automatically applied when connection is created
--
--   * At `Dialog` layer, add `subscribe` function which allows to listen for messages at
--       specified port / specified outbound connection / sum of them.

module Control.TimeWarp.Rpc.MonadTransfer
       ( -- * Related datatypes
         Port
       , Host
       , NetworkAddress
       , Binding (..)
       , localhost
       , commLoggerName
       , commLog

       -- * MonadTransfer
       , MonadTransfer (..)

       -- * MonadResponse
       , MonadResponse (..)
       , ResponseContext (..)
       , ResponseT (..)
       , runResponseT
       , mapResponseT
       , hoistRespCond
       ) where

import           Control.Lens                (iso, view)
import           Control.Monad.Catch         (MonadCatch, MonadMask, MonadThrow)
import           Control.Monad.Morph         (hoist)
import           Control.Monad.Reader        (MonadReader (..), ReaderT (..), mapReaderT)
import           Control.Monad.State         (MonadState)
import           Control.Monad.Trans         (MonadIO (..), MonadTrans (..))
import           Control.Monad.Trans.Control (MonadTransControl (..))
import           Data.ByteString             (ByteString)
import           Data.Conduit                (ConduitM, Producer, Sink, Source)
import           Data.Monoid                 ((<>))
import           Data.Text                   (Text)
import           Data.Word                   (Word16)
import           System.Wlog                 (CanLog, HasLoggerName, LoggerName,
                                              LoggerNameBox (..), WithLogger,
                                              modifyLoggerName)

import           Serokell.Util.Lens          (WrappedM (..), _UnwrappedM)

import           Control.TimeWarp.Timed      (MonadTimed, ThreadId)


-- * Related datatypes

-- | Port number.
type Port = Word16

-- | Host address.
type Host = ByteString

-- | @"127.0.0.1"@.
localhost :: Host
localhost = "127.0.0.1"

-- | Full node address.
type NetworkAddress = (Host, Port)

-- | Name of logger responsible for communication events - @comm@.
-- TODO: Make non-hardcoded.
commLoggerName :: LoggerName
commLoggerName = "comm"

-- | Appends `commLoggerName` as suffix to current logger name.
commLog :: HasLoggerName m => m a -> m a
commLog = modifyLoggerName (<> commLoggerName)

-- | Specifies type of `listen` binding.
--
-- UPGRADE-NOTE: adding /Loopback/ binding may be useful.
data Binding
    = AtPort Port              -- ^ Listen at port
    | AtConnTo NetworkAddress  -- ^ Listen at connection established earlier
    deriving (Eq, Ord, Show)


-- * MonadTransfer

-- | Allows to send/receive raw byte sequences.
class Monad m => MonadTransfer s m | m -> s where
    -- | Sends raw data.
    -- When invoked several times for same address, this function is expected to
    -- use same connection kept under hood.
    -- Byte sequence, produced by given source, will be transmitted as a whole;
    sendRaw :: NetworkAddress       -- ^ Destination address
            -> Source m ByteString  -- ^ Data to send
            -> m ()
    default sendRaw :: (WrappedM m, MonadTransfer s (UnwrappedM m))
                    => NetworkAddress -> Source m ByteString -> m ()
    sendRaw addr req = view _UnwrappedM $
        sendRaw addr $ view _WrappedM `hoist` req

    -- | Listens at specified input or output connection.
    -- Returns server stopper, which blocks current thread until server is actually
    -- stopped.
    -- Calling this function in case there is defined listener already for this
    -- connection should lead to error.
    listenRaw :: Binding                             -- ^ Port/address to listen to
              -> Sink ByteString (ResponseT s m) ()  -- ^ Parser for input byte stream
              -> m (m ())                            -- ^ Server stopper
    default listenRaw :: (WrappedM m, MonadTransfer s (UnwrappedM m))
                      => Binding -> Sink ByteString (ResponseT s m) () -> m (m ())
    listenRaw binding sink = view _UnwrappedM $ fmap (view _UnwrappedM) $
            listenRaw binding $ view _WrappedM `hoistRespCond` sink

    -- | Closes outbound connection to specified node, if exists.
    -- To close inbound connections, use `closeR`.
    close :: NetworkAddress -> m ()
    default close :: (WrappedM m, MonadTransfer s (UnwrappedM m))
                  => NetworkAddress -> m ()
    close = view _UnwrappedM . close

    -- | Gets state, attached to related socket.
    -- If such connection doesn't exist, it would be created.
    userState :: NetworkAddress -> m s
    default userState :: (WrappedM m, MonadTransfer s (UnwrappedM m))
                      => NetworkAddress -> m s
    userState = view _UnwrappedM . userState


-- * MonadResponse

-- | Provides operations related to /peer/ node. Peer is a node, which this node is
-- currently communicating with.
class Monad m => MonadResponse s m | m -> s where
    -- | Sends data to peer.
    replyRaw :: Producer m ByteString -> m ()

    -- | Closes connection with peer.
    closeR :: m ()

    -- | Gets address of peer, for debugging purposes only.
    peerAddr :: m Text

    -- | Get state attached to socket.
    userStateR :: m s
    default userStateR :: MonadTrans t => t m s
    userStateR = lift userStateR


-- | Keeps information about peer.
data ResponseContext s = ResponseContext
    { respSend      :: forall m . (MonadIO m, MonadMask m, WithLogger m)
                    => Source m ByteString -> m ()
    , respClose     :: IO ()
    , respPeerAddr  :: Text
    , respUserState :: s
    }

-- | Default implementation of `MonadResponse`.
newtype ResponseT s m a = ResponseT
    { getResponseT :: ReaderT (ResponseContext s) m a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadTrans,
                MonadThrow, MonadCatch, MonadMask,
                MonadState ss, CanLog,
                HasLoggerName, MonadTimed)

-- | Unwrappes `ResponseT`.
runResponseT :: ResponseT s m a -> ResponseContext s -> m a
runResponseT = runReaderT . getResponseT

instance Monad m => WrappedM (ResponseT s m) where
    type UnwrappedM (ResponseT s m) = ReaderT (ResponseContext s) m
    _WrappedM = iso getResponseT ResponseT

type instance ThreadId (ResponseT s m) = ThreadId m

instance MonadReader r m => MonadReader r (ResponseT s m) where
    ask = lift ask
    reader f = lift $ reader f
    local = mapResponseT . local

instance MonadTransfer s m => MonadTransfer s (ResponseT s0 m) where

instance (MonadIO m, MonadMask m, WithLogger m)
         => MonadResponse s (ResponseT s m) where
    replyRaw dat = ResponseT ask >>= \ctx -> respSend ctx dat

    closeR = ResponseT $ ask >>= liftIO . respClose

    peerAddr = respPeerAddr <$> ResponseT ask

    userStateR = respUserState <$> ResponseT ask

-- | Maps entry of `ResponseT`.
-- TODO: implement `hoist` instead, it should be enough.
mapResponseT :: (m a -> n b) -> ResponseT s m a -> ResponseT s n b
mapResponseT how = ResponseT . mapReaderT how . getResponseT


-- * Instances

-- | Allows to modify entry of @Conduit i o (ResponseT m) r@.
hoistRespCond :: Monad m
              => (forall a . m a -> n a)
              -> ConduitM i o (ResponseT s m) r
              -> ConduitM i o (ResponseT s n) r
hoistRespCond how = hoist $ mapResponseT how

instance MonadTransfer s m => MonadTransfer s (ReaderT r m) where
    sendRaw addr req = ask >>= \ctx -> lift $ sendRaw addr (hoist (`runReaderT` ctx) req)
    listenRaw binding sink =
        fmap lift $ liftWith $ \run -> listenRaw binding $ hoistRespCond run sink
    close = lift . close
    userState = lift . userState

instance MonadTransfer s m => MonadTransfer s (LoggerNameBox m) where

instance MonadResponse s m => MonadResponse s (ReaderT r m) where
    replyRaw dat = ask >>= \ctx -> lift $ replyRaw (hoist (`runReaderT` ctx) dat)
    closeR = lift closeR
    peerAddr = lift peerAddr
