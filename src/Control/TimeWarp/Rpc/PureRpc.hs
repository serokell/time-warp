{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Control.TimeWarp.Rpc.PureRpc
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- Defines network-emulated implementation of `MonadRpc`. Threads and time are
-- also emulated via `Control.TimeWarp.Timed.TimedT`.
module Control.TimeWarp.Rpc.PureRpc
       ( pureSendCap
       , pureRpcCap
       ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, modifyTVar', newTVarIO, readTVarIO)
import Control.Monad (forM_, unless)
import Control.Monad.Catch (MonadThrow (..))
import Control.Monad.Reader (ask, runReaderT)
import Control.Monad.Trans (MonadIO, lift, liftIO)
import qualified Data.Map as Map
import Data.Typeable ((:~:) (..), Typeable, eqT)
import Formatting (sformat, shown, (%))
import Monad.Capabilities (CapImpl (..), CapsT, HasCap)

import Data.MessagePack.Object (MessagePack)

import Control.TimeWarp.Rpc.MonadRpc (Host, MessageId, Method (..), Mode (..), ModeResponseMod,
                                      Port, Rpc (..), RpcError (..), RpcRequest (..), Send (..),
                                      hoistMethod, localhost, methodMessageId, proxyOf)
import Control.TimeWarp.Timed (Timed, sleepForever)

-- | Keeps servers' methods.
type Listeners mode m = Map.Map (Port, MessageId) (Method mode m)

initListeners :: forall mode m. Map.Map (Port, MessageId) (Method mode m)
initListeners = mempty

request :: forall mode r caps m.
           (MonadThrow m, RpcRequest r, MessagePack r, Typeable r)
        => r
        -> Listeners mode m
        -> Port
        -> CapsT caps m (ModeResponseMod mode (Response r))
request req listeners port =
    case Map.lookup (port, name) listeners of
        Nothing -> throwM $ NetworkProblem $
            sformat ("Method " % shown % " not found at port " % shown)
            name port
        Just (Method f) ->
            case canApply f req of
                Nothing   -> error "Duplicated message ids"
                Just Refl -> lift $ f req
  where
    name = messageId $ proxyOf req
    canApply :: (Typeable a, Typeable c) => (a -> b) -> c -> Maybe (a :~: c)
    canApply _ _ = eqT

pureSend
    :: (MonadIO m, MonadThrow m, RpcRequest r)
    => TVar (Listeners mode m)
    -> (Host, Port)
    -> r
    -> CapsT caps m (ModeResponseMod mode (Response r))
pureSend listeners (host, port) req = do
    unless (host == localhost) $
        error "Can't emulate for host /= localhost"
    ls <- liftIO $ readTVarIO listeners
    request req ls port

pureListen
    :: (MonadIO m, HasCap Timed caps)
    => TVar (Listeners mode m)
    -> Port
    -> [Method mode (CapsT caps m)]
    -> CapsT caps m a
pureListen listeners port methods = do
    caps <- ask
    lift $ forM_ methods $ \method -> do
        let methodIx = (port, methodMessageId method)
            method' = hoistMethod (`runReaderT` caps) method
        liftIO . atomically . modifyTVar' listeners $ \li -> do
            if Map.member methodIx li
            then alreadyBindedError
            else Map.insert methodIx method' li
    sleepForever
  where
    alreadyBindedError = error $ concat
        [ "Can't launch server, port "
        , show port
        , " is already bisy"
        ]

-- | Implementation of RPC protocol for emulation, allows to manually define
-- network nastiness via `Delays` datatype. TCP model is used.
--
-- List of known issues:
--
--     * Method, once being declared in net, can't be removed.
-- Even `throwTo` won't help.
--
--     * In implementation, remote method is actually inlined at call position,
-- so @instance WithNamedLogger@ would refer to caller's logger name, not
-- server's one.
pureRpcCap
    :: forall m n.
       (MonadIO m, MonadThrow m, MonadIO n)
    => n (CapImpl Rpc '[Timed] m)
pureRpcCap = do
    listeners <- liftIO $ newTVarIO (initListeners @'RemoteCall @m)
    return $ CapImpl $ Rpc
        { _call = pureSend listeners
        , _serve = pureListen listeners
        }

pureSendCap
    :: forall m n.
       (MonadIO m, MonadThrow m, MonadIO n)
    => n (CapImpl Send '[Timed] m)
pureSendCap = do
    listeners <- liftIO $ newTVarIO (initListeners @'OneWay @m)
    return $ CapImpl Send
        { _send = pureSend listeners
        , _listen = pureListen listeners
        }
