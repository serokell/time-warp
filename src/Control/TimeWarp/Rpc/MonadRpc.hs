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

       , RpcRequest (..)
       , MonadRpc (..)
       , sendTimeout
       , submit
       , Method (..)
       , MethodTry (..)
       , getMethodName
       , proxyOf
       , mkMethodTry
       , hoistMethod
       , RpcError (..)
       ) where

import           Control.Exception        (Exception)
import           Control.Monad            (void)
import           Control.Monad.Catch      (MonadCatch, MonadThrow (..), catchAll, try)
import           Control.Monad.Reader     (ReaderT (..))
import           Control.Monad.Trans      (lift)
import           Data.ByteString          (ByteString)
import           Data.Monoid              ((<>))
import           Data.Proxy               (Proxy (..), asProxyTypeOf)
import           Data.Text                (Text)
import           Data.Text.Buildable      (Buildable (..))

import           Data.MessagePack.Object  (MessagePack (..))
import           Data.Time.Units          (Hour, TimeUnit)

import           Control.TimeWarp.Logging (LoggerNameBox (..))
import           Control.TimeWarp.Timed   (MonadTimed (timeout), fork_)


-- | Port number.
type Port = Int

-- | Host address.
type Host = ByteString

localhost :: Host
localhost = "127.0.0.1"

-- | Full node address.
type NetworkAddress = (Host, Port)

-- | Defines name, response and expected error types of RPC-method to which data
-- of @req@ type can be delivered.
-- Expected error is the one which remote method can catch and send to client;
-- any other error in remote method raises `InternalError` at client side.
--
-- TODO: create instances of this class by TH.
class (MessagePack r, MessagePack (Response r),
       MessagePack (ExpectedError r), Exception (ExpectedError r)) =>
       RpcRequest r where
    type Response r :: *

    type ExpectedError r :: *

    methodName :: Proxy r -> String

-- | Creates RPC-method.
data Method m =
    forall r . RpcRequest r => Method (r -> m (Response r))

-- | Creates RPC-method, which catches exception of `err` type.
data MethodTry m =
    forall r . RpcRequest r =>
    MethodTry (r -> m (Either (ExpectedError r) (Response r)))

mkMethodTry :: MonadCatch m => Method m -> MethodTry m
mkMethodTry (Method f) = MethodTry $ try . f

-- | Defines protocol of RPC layer.
class MonadThrow m => MonadRpc m where
    -- | Executes remote method call.
    send :: RpcRequest r
         => NetworkAddress -> r -> m (Response r)

    -- | Starts RPC server with a set of RPC methods.
    serve :: Port -> [Method m] -> m ()

-- | Same as `send`, but allows to set up timeout for a call (see
-- `Control.TimeWarp.Timed.MonadTimed.timeout`).
sendTimeout
    :: (MonadTimed m, MonadRpc m, RpcRequest r, TimeUnit t)
    => t -> NetworkAddress -> r -> m (Response r)
sendTimeout t addr = timeout t . send addr

-- | Similar to `send`, but doesn't wait for result.
submit
    :: (MonadCatch m, MonadTimed m, MonadRpc m, RpcRequest r)
    => NetworkAddress -> r -> m ()
submit addr req =
    fork_ $ void (sendTimeout timeoutDelay addr req) `catchAll` \_ -> return ()
  where
    -- without timeout emulation has no choice but to hang on blackouts
    timeoutDelay = 1 :: Hour

getMethodName :: Method m -> String
getMethodName (Method f) = let rp = Proxy :: RpcRequest r => Proxy r
                               -- make rp contain type of f's argument
                               _ = f $ undefined `asProxyTypeOf` rp
                           in  methodName rp

proxyOf :: a -> Proxy a
proxyOf _ = Proxy

hoistMethod :: (forall a. m a -> n a) -> Method m -> Method n
hoistMethod hoist' (Method f) = Method (hoist' . f)

-- * Instances

instance MonadRpc m => MonadRpc (ReaderT r m) where
    send addr req = lift $ send addr req

    serve port methods = ReaderT $
                            \r -> serve port (convert r <$> methods)
      where
        convert :: r -> Method (ReaderT r m) -> Method m
        convert r (Method f) = Method $ flip runReaderT r . f

deriving instance MonadRpc m => MonadRpc (LoggerNameBox m)

-- * Exceptions

-- | Exception which can be thrown on `send` call.
data RpcError = -- | Can't find remote method on server's side die to
                -- network problems or lack of such service
                NetworkProblem Text
                -- | Error in RPC protocol with description, or server
                -- threw unserializable error
              | InternalError Text
                -- | Error thrown by server's method
              | forall e . (MessagePack e, Exception e) => ServerError e

instance Buildable RpcError where
    build (NetworkProblem msg) = "Network problem: " <> build msg
    build (InternalError msg)  = "Internal error: " <> build msg
    build (ServerError e)      = "Server reports error: " <> build (show e)

instance Show RpcError where
    show = show . build

instance Exception RpcError
