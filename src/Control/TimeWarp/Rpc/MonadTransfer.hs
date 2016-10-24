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

       , RpcError (..)
       ) where

import           Control.Exception        (Exception)
import           Control.Monad.Catch      (MonadCatch, MonadMask, MonadThrow)
import           Control.Monad.Reader     (MonadReader (..), ReaderT (..), mapReaderT)
import           Control.Monad.State      (MonadState)
import           Control.Monad.Trans      (MonadIO (..), MonadTrans (..))
import           Data.ByteString          (ByteString)
import           Data.Conduit             (Conduit, Producer)
import           Data.Monoid              ((<>))
import           Data.Text                (Text)
import           Data.Text.Buildable      (Buildable (..))

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
    sendRaw :: NetworkAddress          -- ^ Destination address
            -> Producer IO ByteString  -- ^ Data to send
            -> m ()

    -- | Listens at specified input or output connection.
    listenRaw :: Binding                  -- ^ Port/address to listen to
              -> Conduit ByteString IO a  -- ^ Parser for input byte stream
              -> (a -> ResponseT m ())    -- ^ Handler for received data
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
    { respSend  :: Producer IO ByteString -> IO ()
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

    listenRaw binding parser listener =
        ReaderT $ \r -> listenRaw binding parser $
                        mapResponseT (flip runReaderT r) . listener

    close = lift . close

deriving instance MonadTransfer m => MonadTransfer (LoggerNameBox m)
