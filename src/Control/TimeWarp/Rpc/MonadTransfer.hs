{-# LANGUAGE AllowAmbiguousTypes       #-}
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
       , Binding (..)
       , localhost

       , MonadTransfer (..)

       , MonadResponse (..)
       , ResponseContext (..)
       , ResponseT (..)
       , runResponseT
       , mapResponseT

       , hoistRespCond

       , RpcError (..)
       ) where

import           Control.Exception        (Exception)
import           Control.Monad.Catch      (MonadCatch, MonadMask, MonadThrow)
import           Control.Monad.Reader     (MonadReader (..), ReaderT (..), mapReaderT)
import           Control.Monad.State      (MonadState)
import           Control.Monad.Trans      (MonadIO (..), MonadTrans (..))
import           Control.Monad.Trans.Control (MonadTransControl (..))
import           Control.Monad.Morph      (hoist)
import           Data.ByteString          (ByteString)
import           Data.Conduit             (Producer, Sink, ConduitM)
import           Data.Monoid              ((<>))
import           Data.Text                (Text)
import           Data.Text.Buildable      (Buildable (..))
import           Data.Word                (Word16)

import           Control.TimeWarp.Logging (LoggerNameBox (..), WithNamedLogger)
import           Control.TimeWarp.Timed   (MonadTimed, ThreadId)


data Binding
    = AtPort Port              -- ^ Listen at port
    | AtConnTo NetworkAddress  -- ^ Listen at connection established earlier
--    | Loopback                 -- ^ Listen at local pseudo-net (might be usefull)

-- * MonadTransfer

-- | Allows to send/receive raw byte sequences.
class Monad m => MonadTransfer m where
    -- | Sends raw data.
    -- TODO: NetworkAddress -> Consumer ByteString m ()
    sendRaw :: NetworkAddress          -- ^ Destination address
            -> Producer IO ByteString  -- ^ Data to send
            -> m ()

    -- | Listens at specified input or output connection.
    listenRaw :: Binding                           -- ^ Port/address to listen to
              -> Sink ByteString (ResponseT m) ()  -- ^ Parser for input byte stream
              -> m ()

    -- | Closes connection to specified node, if exists.
    close :: NetworkAddress -> m ()


-- * MonadResponse

-- | Provides operations related to /peer/ node. Peer is a node, which this node is
-- currently communicating with.
class Monad m => MonadResponse m where
    replyRaw :: Producer IO ByteString -> m ()

    closeR :: m ()

data ResponseContext = ResponseContext
    { respSend  :: forall m . (MonadIO m, MonadMask m)
                => Producer m ByteString -> m ()
    , respClose :: IO ()
    }

newtype ResponseT m a = ResponseT
    { getResponseT :: ReaderT ResponseContext m a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadTrans,
                MonadThrow, MonadCatch, MonadMask,
                MonadState s,
                WithNamedLogger, MonadTimed)

runResponseT :: ResponseT m a -> ResponseContext -> m a
runResponseT = runReaderT . getResponseT

type instance ThreadId (ResponseT m) = ThreadId m

instance MonadReader r m => MonadReader r (ResponseT m) where
    ask = lift ask
    reader f = lift $ reader f
    local = mapResponseT . local

instance MonadTransfer m => MonadTransfer (ResponseT m) where
    sendRaw addr src = lift $ sendRaw addr src
    listenRaw binding sink =
        ResponseT $ listenRaw binding $ hoistRespCond getResponseT sink
    close addr = lift $ close addr

instance (MonadTransfer m, MonadIO m) => MonadResponse (ResponseT m) where
    replyRaw dat = ResponseT $ ask >>= \ctx -> liftIO $ respSend ctx dat

    closeR = ResponseT $ ask >>= liftIO . respClose

mapResponseT :: (m a -> n b) -> ResponseT m a -> ResponseT n b
mapResponseT how = ResponseT . mapReaderT how . getResponseT

-- * Related datatypes

-- | Port number.
type Port = Word16

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

hoistRespCond :: Monad m
              => (forall a . m a -> n a)
              -> ConduitM i o (ResponseT m) r
              -> ConduitM i o (ResponseT n) r
hoistRespCond how = hoist $ mapResponseT how

instance MonadTransfer m => MonadTransfer (ReaderT r m) where
    sendRaw addr req = lift $ sendRaw addr req
    listenRaw binding sink =
        liftWith $ \run -> listenRaw binding $ hoistRespCond run sink
    close = lift . close

instance MonadTransfer m => MonadTransfer (LoggerNameBox m) where
    sendRaw addr req = lift $ sendRaw addr req
    listenRaw binding sink = 
        LoggerNameBox $ listenRaw binding $ hoistRespCond loggerNameBoxEntry sink
    close = lift . close

instance MonadResponse m => MonadResponse (ReaderT r m) where
    replyRaw x = lift $ replyRaw x
    closeR = lift closeR
