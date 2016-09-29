{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}

-- |
-- Module      : Control.TimeWarp.Rpc.MsgPackRpc
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module contains implementation of `MonadRpc` for real mode
-- (network, time- and thread-management capabilities provided by OS are used).

module Control.TimeWarp.Rpc.MsgPackRpc
       ( MsgPackRpc
       , runMsgPackRpc
       ) where

import qualified Control.Concurrent            as C
import           Control.Monad.Base            (MonadBase)
import           Control.Monad.Catch           (MonadCatch, MonadMask,
                                                MonadThrow)
import           Control.Monad.Trans           (MonadIO (..))
import           Control.Monad.Trans.Control   (MonadBaseControl, StM,
                                                liftBaseWith, restoreM)

import           Data.IORef                    (newIORef, readIORef, writeIORef)
import           Data.Maybe                    (fromMaybe)

import qualified Network.MessagePack.Client    as C
import qualified Network.MessagePack.Server    as S

import           Control.TimeWarp.Rpc.MonadRpc (Method (..), MonadRpc (..),
                                                TransmitionPair (..), getMethodName,
                                                proxyOf)
import           Control.TimeWarp.Timed        (MonadTimed (..), TimedIO, ThreadId,
                                                runTimedIO)

-- | Wrapper over `Control.TimeWarp.Timed.TimedIO`, which implements `MonadRpc`
-- using <https://hackage.haskell.org/package/msgpack-rpc-1.0.0 msgpack-rpc>.
newtype MsgPackRpc a = MsgPackRpc
    { -- | Launches distributed scenario using real network, threads and time.
      unwrapMsgPackRpc :: TimedIO a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadBase IO,
                MonadThrow, MonadCatch, MonadMask, MonadTimed)

runMsgPackRpc :: MsgPackRpc a -> IO a
runMsgPackRpc = runTimedIO . unwrapMsgPackRpc

type instance ThreadId MsgPackRpc = C.ThreadId

instance MonadBaseControl IO MsgPackRpc where
    type StM MsgPackRpc a = a

    liftBaseWith f = MsgPackRpc $ liftBaseWith $ \g -> f $ g . unwrapMsgPackRpc

    restoreM = MsgPackRpc . restoreM

instance MonadRpc MsgPackRpc where
    send (addr, port) req = liftIO $ do
        box <- newIORef Nothing
        C.execClient addr port $ do
            res <- C.call (methodName $ proxyOf req) req
            liftIO . writeIORef box $ Just res
        fromMaybe (error "execClient didn't return a value!")
            <$> readIORef box

    serve port methods = S.serve port $ convertMethod <$> methods
      where
        convertMethod :: Method MsgPackRpc -> S.Method MsgPackRpc
        convertMethod m@(Method f) = S.method (getMethodName m) (S.ServerT . f)

{-
instance S.MethodType MsgPackRpc f => S.MethodType MsgPackRpc (MsgPackRpc f)
   where
    toBody res args = res >>= flip S.toBody args
-}
