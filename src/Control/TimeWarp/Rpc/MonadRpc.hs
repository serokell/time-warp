{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE FunctionalDependencies    #-}
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

       , TransmissionPair (methodName)
       , MonadRpc (..)
       , sendTimeout
       , Method (..)
       , getMethodName
       , proxyOf
       , RpcError (..)
       ) where

import           Control.Exception          (Exception)
import           Control.Monad.Catch        (MonadThrow (..))
import           Control.Monad.Reader       (ReaderT (..))
import           Control.Monad.Trans        (lift)
import           Data.ByteString            (ByteString)
import           Data.Proxy                 (Proxy (..), asProxyTypeOf)
import           Data.Text                  (Text)

import           Data.MessagePack.Object    (MessagePack(..))
import           Data.Time.Units            (TimeUnit)

import           Control.TimeWarp.Logging   (LoggerNameBox (..))
import           Control.TimeWarp.Timed     (MonadTimed (timeout))


-- | Port number.
type Port = Int

-- | Host address.
type Host = ByteString

localhost :: Host
localhost = "127.0.0.1"

-- | Full node address.
type NetworkAddress = (Host, Port)

-- | Defines name and response type of RPC-method to which data of @req@ type
-- can be delivered.
--
-- TODO: create instances of this class by TH.
class (MessagePack req, MessagePack resp) =>
       TransmissionPair req resp | req -> resp where
    methodName :: Proxy req -> String


-- | Creates RPC-method.
data Method m =
    forall req resp . TransmissionPair req resp => Method (req -> m resp)

-- | Defines protocol of RPC layer.
class MonadThrow m => MonadRpc m where
    -- | Executes remote method call.
    send :: TransmissionPair req resp =>
            NetworkAddress -> req -> m resp

    -- | Starts RPC server with a set of RPC methods.
    serve :: Port -> [Method m] -> m ()

-- | Same as `execClient`, but allows to set up timeout for a call (see
-- `Control.TimeWarp.Timed.MonadTimed.timeout`).
sendTimeout
    :: (MonadTimed m, MonadRpc m, TransmissionPair req resp, TimeUnit t)
    => t -> NetworkAddress -> req -> m resp
sendTimeout t addr = timeout t . send addr

getMethodName :: Method m -> String
getMethodName (Method f) = let rp = requestProxy
                               -- make rp contain type of f's argument
                               _ = f $ undefined `asProxyTypeOf` rp
                           in  methodName rp
  where
    requestProxy :: TransmissionPair req resp => Proxy req
    requestProxy = Proxy

proxyOf :: a -> Proxy a
proxyOf _ = Proxy

-- * Instances

instance MonadRpc m => MonadRpc (ReaderT r m) where
    send addr req = lift $ send addr req

    serve port methods = ReaderT $
                            \r -> serve port (convert r <$> methods)
      where
        convert :: Monad m => r -> Method (ReaderT r m) -> Method m
        convert r (Method f) = Method $ flip runReaderT r . f

deriving instance MonadRpc m => MonadRpc (LoggerNameBox m)

-- * Exceptions

data RpcError = -- | Can't find remote method on server's side die to
                -- network problems or lack of such service
                NetworkProblem Text
                -- | Error in RPC protocol with description
              | InternalError Text
                -- | Error thrown by server's method
              | ServerError
    deriving Show

instance Exception RpcError

