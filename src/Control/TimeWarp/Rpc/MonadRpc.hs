{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TypeFamilies              #-}

-- |
-- Module      : Control.TimeWarp.Rpc.MonadRpc
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
       , Method (..)

       , MonadRpc (..)
       , RpcError (..)
       ) where

import           Control.Exception                 (Exception)
import           Control.Monad.Reader              (ReaderT (..))
import           Control.Monad.Trans               (MonadTrans (..))

import           Control.TimeWarp.Logging          (LoggerNameBox (..))
import           Control.TimeWarp.Rpc.MonadDialog  (MonadDialog (..), NetworkAddress,
                                                    Host, Port, RpcError (..), Message,
                                                    localhost)
import           Control.TimeWarp.Rpc.MonadTransfer (ResponseT (..), mapResponseT)


-- * MonadRpc

-- | Defines protocol of RPC layer.
class MonadDialog m => MonadRpc m where
    -- | Remote method call.
    call :: Request r => NetworkAddress -> r -> m (Response r)

    -- | Starts RPC server with a set of RPC methods.
    serve :: Port -> [Method m] -> m ()


-- * Rpc request

class ( Message r
      , Message (Response r)
      , Message (ExpectedError r)
      , Exception (ExpectedError r)
      ) => Request r where
    type Response r :: *

    type ExpectedError r :: *


-- * Methods

-- | Creates RPC-method.
data Method m =
    forall r . Request r => Method (r -> ResponseT m (Response r))


-- * Instances

instance MonadRpc m => MonadRpc (ReaderT r m) where
    call addr req = lift $ call addr req

    serve port listeners = ReaderT $
                            \r -> serve port (convert r <$> listeners)
      where
        convert r (Method f) = Method $ mapResponseT (flip runReaderT r) . f

deriving instance MonadRpc m => MonadRpc (LoggerNameBox m)

deriving instance MonadRpc m => MonadRpc (ResponseT m)
