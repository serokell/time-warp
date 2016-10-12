{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TypeFamilies              #-}

-- |
-- Module      : Control.TimeWarp.Rpc.MonadDialog
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module allows to send/receive whole messages.

module Control.TimeWarp.Rpc.MonadDialog
       ( Port
       , Host
       , NetworkAddress
       , localhost

       , Message (..)
       , MonadDialog (..)

       , send
       , listen
       , reply
       , Listener (..)
       , getMethodName
       , ResponseT (..)
       , mapResponseT

       , RpcError (..)
       ) where

import           Control.Monad.Catch                (MonadThrow, MonadCatch, MonadMask)
import           Control.Monad.Reader               (MonadReader, ReaderT)
import           Control.Monad.State                (MonadState)
import           Control.Monad.Trans                (MonadIO, lift)
import           Data.Binary                        (Binary, Get, Put, put)
import           Data.Proxy                         (Proxy (..))

import           Control.TimeWarp.Logging           (WithNamedLogger, LoggerNameBox (..))
import           Control.TimeWarp.Timed             (MonadTimed, ThreadId)
import           Control.TimeWarp.Rpc.MonadTransfer (MonadTransfer (..),
                                                     Host, Port, mapResponseT,
                                                     NetworkAddress, ResponseT (..),
                                                     RpcError (..), localhost,
                                                     MonadResponse (..))


-- * MonadRpc

-- | Defines communication based on messages.
class MonadTransfer m => MonadDialog m where
    -- | Way of packing data into raw bytes.
    packMsg :: Message r => r -> m Put

    -- | Way of unpacking raw bytes to data.
    unpackMsg :: Message r => m (Get (r, String))


-- | Sends a message at specified address.
-- This method blocks until message fully delivered.
send :: (MonadDialog m, Message r) => NetworkAddress -> r -> m ()
send addr msg = sendRaw addr =<< packMsg msg

-- | Starts server.
listen :: MonadDialog m => Port -> [Listener m] -> m ()
listen port listeners = listenRaw port $ convert <$> listeners
  where
    convert = undefined
--        flip Variant f $ undefined undefined
--             unpackMsg >>= \(_, name) -> guard $ name == getMethodName m

-- | Sends a message to /peer/ node.
reply :: (MonadDialog m, MonadResponse m, Message r) => r -> m ()
reply msg = peerAddr >>= flip send msg


-- * Listeners

-- | Creates RPC-method.
data Listener m =
    forall r . Message r => Listener (r -> ResponseT m ())

getMethodName :: MonadDialog m => Listener m -> String
getMethodName (Listener f) = methodName $ proxyOfArg f
  where
    proxyOfArg :: (a -> b) -> Proxy a
    proxyOfArg _ = Proxy

class Binary m => Message m where
    methodName :: Proxy m -> String

instance Message () where
    methodName _ = "()"


-- * Default instance

newtype BinaryDialog m a = BinaryDialog (m a)
    deriving (Functor, Applicative, Monad, MonadIO,
              MonadThrow, MonadCatch, MonadMask,
              MonadReader r, MonadState s,
              WithNamedLogger, MonadTimed, MonadTransfer)

type instance ThreadId (BinaryDialog m) = ThreadId m

instance MonadTransfer m => MonadDialog (BinaryDialog m) where
    packMsg = return . put

    unpackMsg = return undefined


-- * Instances

instance MonadDialog m => MonadDialog (ReaderT r m) where
    packMsg = lift . packMsg

    unpackMsg = lift unpackMsg

deriving instance MonadDialog m => MonadDialog (LoggerNameBox m)

instance MonadDialog m => MonadDialog (ResponseT m) where
    packMsg = lift . packMsg

    unpackMsg = undefined
