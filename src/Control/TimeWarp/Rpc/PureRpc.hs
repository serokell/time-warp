{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE TemplateHaskell      #-}
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
       ( PureRpc
       , runPureRpc
       , runPureRpcExt
       ) where

import           Control.Lens                  (at, makeLenses, to, use, (?=))
import           Control.Monad                 (forM_, unless, when)
import           Control.Monad.Catch           (MonadCatch, MonadMask, MonadThrow (..))
import           Control.Monad.State           (MonadState (get, put, state), StateT,
                                                evalStateT)
import           Control.Monad.Trans           (MonadIO, MonadTrans, lift)
import           Data.Default                  (def)
import qualified Data.Map                      as Map
import           Formatting                    (sformat, shown, (%))

import           Data.MessagePack.Object       (MessagePack, fromObject, toObject)

import           Control.TimeWarp.Logging      (WithNamedLogger)
import           Control.TimeWarp.Rpc.MonadRpc (MessageId, Method (..), MonadRpc (..),
                                                Port, RpcError (..), RpcOptionMessagePack,
                                                RpcOptions (..), RpcRequest (..),
                                                localhost, methodMessageId, proxyOf)
import           Control.TimeWarp.Timed        (MonadTimed (..), PureThreadId, ThreadId,
                                                TimedT, TimedTOptions (..), runTimedTExt,
                                                sleepForever)

-- | Pure RPC uses MessagePack for serilization as well.
type LocalOptions = '[RpcOptionMessagePack]

-- | Keeps servers' methods.
type Listeners m = Map.Map (Port, MessageId) (Method LocalOptions m)

-- | Keeps global network information.
data NetInfo m = NetInfo
    { _listeners :: Listeners m
    }

$(makeLenses ''NetInfo)

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
newtype PureRpc m a = PureRpc
    { unwrapPureRpc :: TimedT (StateT (NetInfo (PureRpc m)) m) a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadThrow, MonadCatch,
                MonadMask, WithNamedLogger)

type instance ThreadId (PureRpc m) = PureThreadId

deriving instance (MonadIO m, MonadCatch m) => MonadTimed (PureRpc m)

instance MonadTrans PureRpc where
    lift = PureRpc . lift . lift

instance MonadState s m => MonadState s (PureRpc m) where
    get = lift get
    put = lift . put
    state = lift . state

-- | Launches distributed scenario, emulating work of network.
runPureRpc
    :: (MonadIO m, MonadCatch m)
    => PureRpc m a -> m a
runPureRpc = runPureRpcExt def

-- | Launches distributed scenario, emulating work of network.
runPureRpcExt
    :: (MonadIO m, MonadCatch m)
    => TimedTOptions -> PureRpc m a -> m a
runPureRpcExt options rpc =
    evalStateT (runTimedTExt options $ unwrapPureRpc rpc) net
  where
    net        = NetInfo{..}
    _listeners = Map.empty

request :: (MonadThrow m, RpcRequest r, RpcConstraints LocalOptions r)
        => r
        -> Listeners (PureRpc m)
        -> Port
        -> PureRpc m (Response r)
request req listeners' port =
    case Map.lookup (port, name) listeners' of
        Nothing -> throwM $ NetworkProblem $
            sformat ("Method " % shown % " not found at port " % shown)
            name port
        Just (Method f) -> coerce =<< f =<< coerce req
  where
    name = messageId $ proxyOf req

    -- TODO: how to deceive type checker without serialization?
    coerce :: (MessagePack a, MessagePack b, MonadThrow m) => a -> m b
    coerce = maybe typeError return . fromObject . toObject

    typeError :: MonadThrow m => m a
    typeError = throwM $ InternalError $ sformat $
        "Internal error. Do you have several instances of " %
        "RpcRequest with same methodName?"

instance (MonadIO m, MonadCatch m) =>
         MonadRpc LocalOptions (PureRpc m) where
    send (host, port) req = do
        unless (host == localhost) $
            error "Can't emulate for host /= localhost"
        ls <- PureRpc $ use listeners
        request req ls port
    serve port methods =
        PureRpc $
        do lift $
               forM_ methods $
               \method -> do
                    let methodIx = (port, methodMessageId method)
                    defined <- use $ listeners . to (Map.member methodIx)
                    when defined alreadyBindedError
                    listeners . at methodIx ?= method
           sleepForever
      where
        alreadyBindedError = error $ concat
            [ "Can't launch server, port "
            , show port
            , " is already bisy"
            ]

