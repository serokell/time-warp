{-# LANGUAGE ExplicitForAll        #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
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
       , Delays

       -- * Delay rules
       -- ** Primitives
       , steady
       , constant
       , uniform
       , blackout

       -- ** Combinators
       , frequency

       -- *** Time filtering
       , postponed
       , temporal
       , inTimeRange

       -- *** Address filtering
       , forAddress
       , forAddressesList
       , forAddresses
       ) where

import           Control.Lens                  (at, both, makeLenses, to, use, (%%=),
                                                (%~), (?=))
import           Control.Monad                 (forM_, unless, when)
import           Control.Monad.Catch           (MonadCatch, MonadMask, MonadThrow (..))
import           Control.Monad.Random          (MonadRandom (getRandomR), Rand, runRand)
import           Control.Monad.State           (MonadState (get, put, state), StateT,
                                                evalStateT)
import           Control.Monad.Trans           (MonadIO, MonadTrans, lift)
import           Data.Default                  (Default, def)
import           Data.List                     (find)
import qualified Data.Map                      as Map
import           Data.Maybe                    (fromMaybe)
import qualified Data.Set                      as S
import           Data.Time.Units               (TimeUnit, fromMicroseconds,
                                                toMicroseconds)
import           Formatting                    (sformat, shown, (%))
import           System.Random                 (StdGen)

import           Data.MessagePack.Object       (MessagePack, fromObject, toObject)

import           Control.TimeWarp.Logging      (WithNamedLogger)
import           Control.TimeWarp.Rpc.MonadRpc (Host, Method (..), MonadRpc (..),
                                                NetworkAddress, Port, RpcError (..),
                                                RpcRequest (..), getMethodName, proxyOf)
import           Control.TimeWarp.Timed        (Microsecond, MonadTimed (..),
                                                PureThreadId, ThreadId, TimedT, for,
                                                runTimedT, sleepForever, virtualTime,
                                                wait)

localhost :: Host
localhost = "127.0.0.1"

-- | Describes obstructions occured on executing RPC request.
data ConnectionOutcome
    -- | Connection established in specified amout of time.
    = ConnectedIn Microsecond
    -- | Connection would be never established, client hangs.
    | NeverConnected
    -- | Alternative rule will be tried. If no other rule specified, use 0 delay.
    -- This allows to combine rules via 'Monoid' instance.
    | UndefinedConnectionOutcome

-- | Allows to describe most complicated behaviour of network.
--
-- Examples:
--
-- * Always 1 second delay:
--
-- @
-- constant @Second 1
-- @
--
-- * Delay varies between 1 and 5 seconds (with granularity of 1 mcs):
--
-- @
-- uniform @Second (1, 5)
-- @
--
-- * For first 10 seconds after scenario start connection delay increases from
-- 1 to 2 seconds.
--
-- @
-- mconcat
--     [ temporal (interval 10 sec) $ constant @Second 1
--     , constant @Second 2
--     ]
-- @
--
-- * Node with address `isolatedAddr` is not accessible:
--
-- @
-- forAddress isolatedAddr blackout
-- @
newtype Delays = Delays
    { -- | Basing on current virtual time, rpc method server's
      -- address, returns delay after which server receives RPC request.
      evalDelay :: NetworkAddress
                -> Microsecond
                -> Rand StdGen ConnectionOutcome
    }

-- | This allows to combine delay rules so that, if first rule returns
-- undefined outcome then second is tried and so on.
instance Monoid Delays where
    mempty = Delays $ \_ _ -> pure UndefinedConnectionOutcome

    Delays d1 `mappend` Delays d2 =
        Delays $ \addr time ->
            d1 addr time >>= \case
                UndefinedConnectionOutcome -> d2 addr time
                outcome -> pure outcome

-- | Delays vary in given range uniformly.
uniform :: TimeUnit t => (t, t) -> Delays
uniform range =
    Delays $ \_ _ ->
        ConnectedIn . fromMicroseconds <$>
        getRandomR (both %~ toMicroseconds $ range)

-- | Fixed delay.
constant :: TimeUnit t => t -> Delays
constant t = uniform (t, t)

-- | No delays.
steady :: Delays
steady = constant (0 :: Microsecond)

-- | Message never gets delivered.
blackout :: Delays
blackout = Delays $ \_ _ -> pure NeverConnected

-- | Chooses one of the given delays, with a weighted random distribution.
-- The input list must be non-empty.
frequency :: [(Int, Delays)] -> Delays
frequency [] = error "frequency: list should not be empty!"
frequency distr =
    Delays $ \addr time -> do
        k <- getRandomR (0, total - 1)
        let (_, Delays d) =
              fromMaybe (error "Failed to get distr item") $
              find ((> k) . fst) distr'
        d addr time
  where
    boundaries = tail $ scanl1 (+) $ map fst distr
    total = last boundaries
    distr' = zip boundaries (map snd distr)

-- | Rule activates after given amount of time.
postponed :: Microsecond -> Delays -> Delays
postponed start (Delays delays) =
    Delays $ \addr time -> delays addr (time - start)

-- | Rule is active for given period of time.
temporal :: Microsecond -> Delays -> Delays
temporal duration (Delays delays) =
    Delays $ \addr time ->
        if 0 <= time || time < duration
        then delays addr time
        else pure UndefinedConnectionOutcome

-- | Rule is active in given time range.
inTimeRange :: (Microsecond, Microsecond) -> Delays -> Delays
inTimeRange (start, end) = postponed start . temporal (end - start)

-- | Rule applies to destination addresses which comply predicate.
forAddresses :: (NetworkAddress -> Bool) -> Delays -> Delays
forAddresses fits (Delays delays) =
    Delays $ \addr time ->
        if fits addr
        then delays addr time
        else pure UndefinedConnectionOutcome

-- | Rule applies to given address.
forAddress :: NetworkAddress -> Delays -> Delays
forAddress addr = forAddresses (== addr)

-- | Rule applies to given list of addresses.
forAddressesList :: [NetworkAddress] -> Delays -> Delays
forAddressesList addrs =
    let addrsSet = S.fromList addrs
    in  forAddresses (`S.member` addrsSet)


-- | Describes network nastiness.
class DelaysSpecifier d where
    toDelays :: d -> Delays

-- | Detailed description of network nastiness.
instance DelaysSpecifier Delays where
    toDelays = id

-- | Connection is never established.
instance DelaysSpecifier () where
    toDelays () = blackout

-- | Specifies permanent connection delay.
instance DelaysSpecifier Microsecond where
    toDelays = constant

-- | Connection delay varies is specified range.
instance DelaysSpecifier (Microsecond, Microsecond) where
    toDelays = uniform

-- This is needed for QC.
instance Show Delays where
    show _ = "Delays"

-- | Describes reliable network.
instance Default Delays where
    def = steady

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
    => delays -> StdGen -> PureRpc m a -> m a
runPureRpc (toDelays -> _delays) _randSeed rpc =
    evalStateT (runTimedT $ unwrapPureRpc rpc) net
  where
    net        = NetInfo{..}
    _listeners = Map.empty

request :: (MonadThrow m, RpcRequest r)
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
    name = methodName $ proxyOf req

    -- TODO: how to deceive type checker without serialization?
    coerce :: (MessagePack a, MessagePack b, MonadThrow m) => a -> m b
    coerce = maybe typeError return . fromObject . toObject

    typeError :: MonadThrow m => m a
    typeError = throwM $ InternalError $ sformat $
        "Internal error. Do you have several instances of " %
        "RpcRequest with same methodName?"

instance (MonadIO m, MonadCatch m) =>
         MonadRpc (PureRpc m) where
    send addr@(host, port) req = do
        unless (host == localhost) $
            error "Can't emulate for host /= localhost"
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
                    when defined alreadyBindedError
                    listeners . at methodIx ?= method
           sleepForever
      where
        alreadyBindedError = error $ concat
            [ "Can't launch server, port "
            , show port
            , " is already bisy"
            ]


waitDelay
    :: (MonadThrow m, MonadIO m, MonadCatch m)
    => NetworkAddress -> PureRpc m ()
waitDelay addr =
    PureRpc $
    do delays' <- use delays
       time    <- virtualTime
       delay   <- randSeed %%= runRand (evalDelay delays' addr time)
       case delay of
           ConnectedIn connDelay      -> wait (for connDelay)
           NeverConnected             -> sleepForever
           UndefinedConnectionOutcome -> pure ()
