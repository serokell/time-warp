{-# LANGUAGE ExplicitForAll        #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE ViewPatterns          #-}

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
       , DelaysSpecifier (..)
       , Delays (..)
       , ConnectionOutcome (..)
       , getRandomTR
       ) where

import           Control.Exception.Base        (Exception)
import           Control.Lens                  (both, makeLenses, to, use, (%%=),
                                                (%~), at, (?=))
import           Control.Monad                 (forM_, when)
import           Control.Monad.Catch           (MonadCatch, MonadMask, MonadThrow)
import           Control.Monad.Random          (MonadRandom (getRandomR), Rand, runRand)
import           Control.Monad.State           (MonadState (get, put, state), StateT,
                                                evalStateT)
import           Control.Monad.Trans           (MonadIO, MonadTrans, lift)
import           Data.Default                  (Default, def)
-- import           Formatting                    (sformat, shown, (%))
import           Data.Map                      as Map
import           Data.Maybe                    (fromMaybe)
import           Data.Time.Units               (fromMicroseconds, toMicroseconds)
import           Data.Typeable                 (Typeable)
import           System.Random                 (StdGen)

import           Data.MessagePack.Object       (MessagePack, fromObject, toObject)

import           Control.TimeWarp.Logging      (WithNamedLogger)
import           Control.TimeWarp.Rpc.MonadRpc (MonadRpc (..), proxyOf,
                                                NetworkAddress, Host, Port,
                                                Method (..), getMethodName,
                                                TransmitionPair (..))
import           Control.TimeWarp.Timed        (Microsecond, MonadTimed (..),
                                                PureThreadId, TimedT, for,
                                                virtualTime, runTimedT, sleepForever,
                                                wait, ThreadId)

localhost :: Host
localhost = "127.0.0.1"

-- | Describes obstructions occured on executing RPC request.
data ConnectionOutcome
    -- | Connection established in specified amout of time.
    = ConnectedIn Microsecond
    -- | Connection would be never established, client hangs.
    | NeverConnected

-- | Allows to describe most complicated behaviour of network.
--
-- Examples:
--
-- * Always 1 second delay:
--
-- @
-- Delays $ \\_ _ -> return $ ConnectedIn (interval 1 sec)
-- @
--
-- * Delay varies between 1 and 5 seconds (with granularity of 1 mcs):
--
-- @
-- Delays $ \\_ _ -> ConnectedIn \<$\> getRandomTR (interval 1 sec, interval 5 sec)
-- @
--
-- * For first 10 seconds after scenario start connection is established
-- with probability of 1/6:
--
-- @
-- Delays $ \\_ time -> do
--     p <- getRandomR (0, 5)
--     if (p == 0) && (time <= interval 10 sec)
--         then return $ ConnectedIn 0
--         else return NeverConnected
-- @
--
-- * Node with address `isolatedAddr` is not accessible:
--
-- @
-- Delays $ \\serverAddr _ ->
--     return if serverAddr == isolatedAddr
--            then NeverConnected
--            else ConnectedIn 0
-- @

newtype Delays = Delays
    { -- | Basing on current virtual time, rpc method server's
      -- address, returns delay after which server receives RPC request.
      evalDelay :: NetworkAddress
                -> Microsecond
                -> Rand StdGen ConnectionOutcome
    }

-- | Describes network nastiness.
class DelaysSpecifier d where
    toDelays :: d -> Delays

-- | Detailed description of network nastiness.
instance DelaysSpecifier Delays where
    toDelays = id

-- | Connection is never established.
instance DelaysSpecifier () where
    toDelays = const . Delays . const . const . return $ NeverConnected

-- | Specifies permanent connection delay.
instance DelaysSpecifier Microsecond where
    toDelays = Delays . const . const . return . ConnectedIn

-- | Connection delay varies is specified range.
instance DelaysSpecifier (Microsecond, Microsecond) where
    toDelays = Delays . const . const . fmap ConnectedIn . getRandomTR

-- This is needed for QC.
instance Show Delays where
    show _ = "Delays"

-- | Describes reliable network.
instance Default Delays where
    def = Delays . const . const . return . ConnectedIn $ 0

-- | Return a randomly-selected time value in specified range.
getRandomTR :: MonadRandom m => (Microsecond, Microsecond) -> m Microsecond
getRandomTR = fmap fromMicroseconds . getRandomR . (both %~ toMicroseconds)

-- | Keeps servers' methods.
type Listeners m = Map.Map (Port, String) (Method m)

-- | Keeps global network information.
data NetInfo m = NetInfo
    { _listeners :: Listeners m
    , _randSeed  :: StdGen
    , _delays    :: Delays
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
    :: (MonadIO m, MonadCatch m, DelaysSpecifier delays)
    => StdGen -> delays -> PureRpc m a -> m a
runPureRpc _randSeed (toDelays -> _delays) rpc =
    evalStateT (runTimedT $ unwrapPureRpc rpc) net
  where
    net        = NetInfo{..}
    _listeners = Map.empty

request :: (Monad m, MonadThrow m, TransmitionPair req resp)
        => req
        -> Listeners (PureRpc m)
        -> Port
        -> PureRpc m resp
request req listeners' port =
    case Map.lookup (port, name) listeners' of
        Nothing -> error $ concat
            ["method \"", name, "\" not found at port ", show port]
        Just (Method f) -> fmap coerce . f . coerce $ req
  where
    name = methodName $ proxyOf req

    -- TODO: how to deceive type checker without serialization?
    coerce :: (MessagePack a, MessagePack b) => a -> b
    coerce = fromMaybe typeError . fromObject . toObject

    typeError = error $ "Internal error. Do you have several instances of "
                     ++ "TransmitionPair with same methodName?"

instance (MonadIO m, MonadCatch m) =>
         MonadRpc (PureRpc m) where
    send addr@(host, port) req =
        if host /= localhost
            then
                error "Can't emulate for host /= localhost"
            else do
                waitDelay addr
                ls <- PureRpc $ use listeners
                request req ls port
    serve port methods =
        PureRpc $
        do lift $
               forM_ methods $
               \method -> do
                    let methodIx = (port, getMethodName method)
                    defined <- use $ listeners . to (Map.member methodIx)
                    when defined $ return ()
                    -- TODO:
                    --    throwM $ PortAlreadyBindedError port
                    listeners . at methodIx ?= method
           sleepForever

waitDelay
    :: (MonadThrow m, MonadIO m, MonadCatch m)
    => NetworkAddress -> PureRpc m ()
waitDelay addr =
    PureRpc $
    do delays' <- use delays
       time    <- virtualTime
       delay   <- randSeed %%= runRand (evalDelay delays' addr time)
       case delay of
           ConnectedIn connDelay -> wait (for connDelay)
           NeverConnected        -> sleepForever

data PortAlreadyBindedError = PortAlreadyBindedError Port
    deriving (Show, Typeable)

instance Exception PortAlreadyBindedError
