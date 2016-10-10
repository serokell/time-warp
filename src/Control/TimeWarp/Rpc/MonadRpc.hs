{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TypeFamilies              #-}

-- |
-- Module      : Control.TimeWarp.Rpc
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module contains `MonadRpc` typeclass which abstracts over
-- RPC communication.

module Control.TimeWarp.Rpc.MonadRpc
       ( Port
       , Host
       , NetworkAddress
       , localhost

       , Request (..)
       , Listener (..)
       , getMethodName
       , proxyOf

       , MonadRpc (..)
       , sendTimeout
       , RpcError (..)
       ) where

import           Control.Exception          (Exception)
import           Control.Monad.Reader       (ReaderT (..))
import           Control.Monad.Trans        (MonadTrans (..))
import           Data.ByteString            (ByteString)
import           Data.Monoid                ((<>))
import           Data.Proxy                 (Proxy (..), asProxyTypeOf)
import           Data.Text                  (Text)
import           Data.Text.Buildable        (Buildable (..))

import           Data.MessagePack.Object    (MessagePack (..))
import           Data.Time.Units            (TimeUnit)

import           Control.TimeWarp.Logging   (LoggerNameBox (..))
import           Control.TimeWarp.Timed     (MonadTimed (timeout))


-- * MonadRpc

-- | Defines protocol of RPC layer.
class Monad m => MonadRpc m where
    -- | Sends a message at specified address.
    -- This method blocks until message fully delivered.
    send :: Request r
         => NetworkAddress -> r -> m ()

    -- | Starts RPC server with a set of RPC methods.
    listen :: Port -> [Listener m] -> m ()

    -- | Closes connection to specified node, if exists.
    close :: NetworkAddress -> m ()

-- | Same as `execClient`, but allows to set up timeout for a call (see
-- `Control.TimeWarp.Timed.MonadTimed.timeout`).
sendTimeout
    :: (MonadTimed m, MonadRpc m, Request r, TimeUnit t)
    => t -> NetworkAddress -> r -> m ()
sendTimeout t addr = timeout t . send addr


-- * Listeners

-- | Creates RPC-method.
data Listener m =
    forall r . Request r => Listener (r -> m ())

getMethodName :: Listener m -> String
getMethodName (Listener f) = let rp = Proxy :: Request r => Proxy r
                                 -- make rp contain type of f's argument
                                 _ = f $ undefined `asProxyTypeOf` rp
                             in  methodName rp

proxyOf :: a -> Proxy a
proxyOf _ = Proxy


-- * Related datatypes

-- | Port number.
type Port = Int

-- | Host address.
type Host = ByteString

localhost :: Host
localhost = "127.0.0.1"

-- | Full node address.
type NetworkAddress = (Host, Port)

-- | Defines method name corresponding to this request type.
-- TODO: use ready way to get datatype's name
class MessagePack r => Request r where
    methodName :: Proxy r -> String

instance Request () where
    methodName _ = "()"


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

instance MonadRpc m => MonadRpc (ReaderT r m) where
    send addr req = lift $ send addr req

    listen port listeners = ReaderT $
                            \r -> listen port (convert r <$> listeners)
      where
        convert r (Listener f) =
            Listener $ flip runReaderT r . f

    close = lift . close

instance MonadRpc m => MonadRpc (LoggerNameBox m) where
    send addr req = LoggerNameBox $ send addr req

    listen port listeners = LoggerNameBox $ listen port (convert <$> listeners)
      where
        convert (Listener f) = Listener $ loggerNameBoxEntry . f

    close = lift . close
