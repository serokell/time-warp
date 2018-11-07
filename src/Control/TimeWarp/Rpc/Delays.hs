{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE MultiWayIf           #-}
{-# LANGUAGE Rank2Types           #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Control.TimeWarp.Rpc.Delays
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- Defines monad layer for providing network condition manipulation.
module Control.TimeWarp.Rpc.Delays
       (
       -- * Delay type
         DelaysSpecifier (..)
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

       -- * Applying delay
       , sendDelaysCap
       , rpcDelaysCap
       ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVar, writeTVar)
import Control.Lens (both, (%~))
import Control.Monad.Random (MonadRandom (getRandomR), Rand, evalRand, split)
import Control.Monad.Trans (MonadIO, liftIO)
import Data.Default (Default, def)
import Data.List (find)
import Data.Maybe (fromMaybe)
import qualified Data.Set as S
import Data.Time.Units (TimeUnit, fromMicroseconds, toMicroseconds)
import Monad.Capabilities (CapImpl (..), CapsT, HasCap)
import System.Random (StdGen)

import Control.TimeWarp.Rpc.MonadRpc (NetworkAddress, Rpc (..), Send (..))
import Control.TimeWarp.Timed (Microsecond, Timed, for, fork_, sleepForever, virtualTime, wait)

-- * Delays management

-- | Describes obstructions occured on executing RPC request.
data ConnectionOutcome
    -- | Connection established in specified amout of time.
    = ConnectedIn Microsecond
    -- | Connection would be never established, client hangs.
    | NeverConnected
    -- | Alternative rule will be tried. If no other rule specified, use 0 delay.
    -- This allows to combine rules via 'Monoid' instance.
    | UndefinedConnectionOutcome
    deriving (Show)

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
      evalDelayUnsafe
          :: NetworkAddress
          -> Microsecond
          -> Rand StdGen ConnectionOutcome
    }

evalDelay :: Delays
          -> NetworkAddress
          -> Microsecond
          -> Rand StdGen ConnectionOutcome
evalDelay delays addr time =
    if | time < 0  -> return NeverConnected
       | otherwise -> evalDelayUnsafe delays addr time

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
    boundaries = scanl1 (+) $ map fst distr
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
        if 0 <= time && time < duration
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


-- * Delays layer

waitDelay
    :: (MonadIO m, HasCap Timed caps)
    => TVar StdGen -> Delays -> NetworkAddress -> CapsT caps m ()
waitDelay genVar delays addr = do
    time <- virtualTime
    -- better to fork new gen because delays evaluation may be
    -- inefficient
    gen <- forkGen genVar
    let delay = evalRand (evalDelay delays addr time) gen
    case delay of
        ConnectedIn connDelay      -> wait (for connDelay)
        NeverConnected             -> sleepForever
        UndefinedConnectionOutcome -> pure ()
  where
    forkGen var = liftIO . atomically $ do
        gen <- readTVar var
        let (gen1, gen2) = split gen
        writeTVar var gen1
        return gen2

-- | Modifies 'Send' actions so that messages are delivered with delay.
sendDelaysCap
    :: (MonadIO m, MonadIO n, DelaysSpecifier delays, HasCap Timed deps)
    => delays -> StdGen -> m (CapImpl Send deps n -> CapImpl Send (Timed ': deps) n)
sendDelaysCap (toDelays -> delays) gen = do
    genVar <- liftIO $ newTVarIO gen
    return $ \(CapImpl sendCap) -> CapImpl sendCap
        { _send = \addr req ->
            fork_ $ do
                waitDelay genVar delays addr
                _send sendCap addr req
        }

-- | Modifies 'Rpc' actions so that message passing is delayed; note that
-- delay is applied twice, both on request and response.
rpcDelaysCap
    :: (MonadIO m, MonadIO n, DelaysSpecifier delays, HasCap Timed deps)
    => delays -> StdGen -> m (CapImpl Rpc deps n -> CapImpl Rpc (Timed ': deps) n)
rpcDelaysCap (toDelays -> delays) gen = do
    genVar <- liftIO $ newTVarIO gen
    return $ \(CapImpl rpcCap) -> CapImpl rpcCap
        { _call = \addr req -> do
            waitDelay genVar delays addr
            res <- _call rpcCap addr req
            waitDelay genVar delays addr
            return res
        }
