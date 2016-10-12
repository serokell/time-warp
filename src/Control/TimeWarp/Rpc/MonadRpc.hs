{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TypeFamilies              #-}

-- |
-- Module      : Control.TimeWarp.MonadRpc
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
       , Rpc (..)
       , RpcError (..)
       ) where

import           Control.Monad.Catch               (MonadThrow, MonadCatch, MonadMask)
import           Control.Exception                 (Exception)
import           Control.Monad.Reader              (ReaderT (..), MonadReader)
import           Control.Monad.State               (MonadState)
import           Control.Monad.Trans               (MonadTrans (..), MonadIO)


import           Control.TimeWarp.Logging          (WithNamedLogger, LoggerNameBox (..))
import           Control.TimeWarp.Timed.MonadTimed (MonadTimed, ThreadId)
import           Control.TimeWarp.Rpc.MonadDialog  (MonadDialog (..), NetworkAddress,
                                                    Host, Port, RpcError (..), Message,
                                                    localhost, ResponseT (..),
                                                    mapResponseT)
import           Control.TimeWarp.Rpc.MonadTransfer (MonadTransfer)


-- * MonadRpc

-- | Defines protocol of RPC layer.
class MonadDialog m => MonadRpc m where
    -- | Remote method call.
    call :: NetworkAddress -> r -> m (Response r)

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


-- * Default instance of `MonadRpc`

newtype Rpc m a = Rpc
    { runRpc :: m a
    } deriving (Functor, Applicative, Monad, MonadIO,
                MonadThrow, MonadCatch, MonadMask,
                MonadReader r, MonadState s,
                WithNamedLogger, MonadTimed, MonadTransfer, MonadDialog)

type instance ThreadId (Rpc m) = ThreadId m

instance MonadDialog m => MonadRpc (Rpc m) where
    call = undefined

    serve = undefined


-- * Instances

instance MonadRpc m => MonadRpc (ReaderT r m) where
    call addr req = lift $ call addr req

    serve port listeners = ReaderT $
                            \r -> serve port (convert r <$> listeners)
      where
        convert r (Method f) =
            Method $ mapResponseT (flip runReaderT r) . f

instance MonadRpc m => MonadRpc (LoggerNameBox m) where
    call addr req = LoggerNameBox $ call addr req

    serve port listeners = LoggerNameBox $ serve port (convert <$> listeners)
      where
        convert (Method f) =
            Method $ mapResponseT loggerNameBoxEntry . f

deriving instance MonadRpc m => MonadRpc (ResponseT m)
