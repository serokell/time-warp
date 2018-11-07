{-# LANGUAGE Rank2Types           #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Control.TimeWarp.Timed.MonadTimed
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module defines typeclass `MonadTimed` with basic functions
-- to manipulate time and threads.
module Control.TimeWarp.Timed.MonadTimed
    ( -- * Typeclass with basic functions
      Timed (..)
    , ThreadId (..)
    , RelativeToNow
      -- * Helper functions
    , virtualTime, currentTime, wait, fork, myThreadId, throwTo, timeout
    , schedule, invoke, timestamp, fork_, work, killThread
    , startTimer
      -- ** Time measures
    , hour , minute , sec , ms , mcs
    , hour', minute', sec', ms', mcs'
      -- ** Time specifiers
      -- $timespec
    , for, after, till, at, now
    , interval, timepoint
      -- * Time types
      -- | Re-export of Data.Time.Units.Microsecond
    , Microsecond
      -- | Re-export of Data.Time.Units.Millisecond
    , Millisecond
      -- | Re-export of Data.Time.Units.Second
    , Second
      -- | Re-export of Data.Time.Units.Minute
    , Minute
      -- * Time accumulators
      -- $timeacc
    , TimeAccR
    , TimeAccM
      -- * Exceptions
    , MonadTimedError (..)
    ) where

import qualified Control.Concurrent as C
import Control.Exception (AsyncException (ThreadKilled), Exception (..))
import Control.Monad (void)
import Control.Monad.Trans (MonadIO, liftIO)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Text.Buildable (Buildable (build))
import Data.Time.Units (Microsecond, Millisecond, Minute, Second, TimeUnit (..), convertUnit)
import Data.Typeable (Typeable)
import Monad.Capabilities (CapsT, HasCap, withCap)

-- | Defines some time point basing on current virtual time.
type RelativeToNow = Microsecond -> Microsecond

-- | Is arisen on call of `timeout` if action wasn't executed in time.
data MonadTimedError
    = MTTimeoutError Text
    deriving (Show, Typeable)

instance Exception MonadTimedError

instance Buildable MonadTimedError where
    build (MTTimeoutError t) = "timeout error: " <> build t

data ThreadId
    = RealThreadId C.ThreadId
    | EmuThreadId Integer

-- | Allows time management. Time is specified in microseconds passed
--   from launch point (/origin/), this time is further called /virtual time/.
--
-- Instance of MonadTimed should satisfy the following law:
--
--     * when defining instance of MonadTrans for a monad,
-- information stored inside the transformer should be tied to thread, and
-- get cloned on `fork`s.
--
-- For example,
-- @instance MonadTimed m => MonadTimed (StateT s m)@
-- is declared such that:
--
-- @
-- example :: (MonadTimed m, MonadIO m) => StateT Int m ()
-- example = do
--     put 1
--     fork $ put 10     -- main thread won't be touched
--     wait $ for 1 sec  -- wait for forked thread to execute
--     liftIO . print =<< get
-- @
--
-- >>> runTimedT $ runStateT undefined example
-- 1
--
-- When implement instance of this typeclass, don't forget to define `ThreadId`
-- first.
data Timed m = Timed
    { _virtualTime :: m Microsecond
    , _currentTime :: m Microsecond
    , _wait        :: RelativeToNow -> m ()
    , _fork        :: m () -> m ThreadId
    , _myThreadId  :: m ThreadId
    , _throwTo     :: forall e. Exception e => ThreadId -> e -> m ()
    , _timeout     :: forall t a. TimeUnit t => t -> m a -> m a
    }

-- | Acquires virtual time.
virtualTime :: HasCap Timed caps => CapsT caps m Microsecond
virtualTime = withCap _virtualTime

-- | Acquires (pseudo-)real time.
currentTime :: HasCap Timed caps => CapsT caps m Microsecond
currentTime = withCap _currentTime

-- | Waits for specified amount of time.
--
-- Use `for` to specify relative virtual time (counting from now),
-- and `till` for absolute one.
--
-- >>> runTimedT $ wait (for 1 sec) >> wait (for 5 sec) >> timestamp "now"
-- [6000000µs] now
-- >>> runTimedT $ wait (for 1 sec) >> wait (till 5 sec) >> timestamp "now"
-- [5000000µs] now
-- >>> runTimedT $ wait (for 10 minute 34 sec 52 ms) >> timestamp "now"
-- [634052000µs] now
wait :: HasCap Timed caps => RelativeToNow -> CapsT caps m ()
wait relTime = withCap $ \cap -> _wait cap relTime

-- | Creates another thread of execution, with same point of origin.
fork :: HasCap Timed caps => CapsT caps m () -> CapsT caps m ThreadId
fork act = withCap $ \cap -> _fork cap act

-- | Acquires current thread id.
myThreadId :: HasCap Timed caps => CapsT caps m ThreadId
myThreadId = withCap _myThreadId

-- | Arises specified exception in specified thread.
throwTo :: (HasCap Timed caps, Exception e) => ThreadId -> e -> CapsT caps m ()
throwTo tid e = withCap $ \cap -> _throwTo cap tid e

-- | Throws a `MTTimeoutError` exception
-- if running action exceeds specified time.
timeout :: (HasCap Timed caps, TimeUnit t) => t -> CapsT caps m a -> CapsT caps m a
timeout time act = withCap $ \cap -> _timeout cap time act

-- | Executes an action somewhere in future in another thread.
-- Use `after` to specify relative virtual time (counting from now),
-- and `at` for absolute one.
--
-- @
-- schedule time action ≡ fork_ $ wait time >> action
-- @
--
-- @
-- example :: (MonadTimed m, MonadIO m) => CapsT caps m ()
-- example = do
--     wait (for 10 sec)
--     schedule (after 3 sec) $ timestamp "This would happen at 13 sec"
--     schedule (at 15 sec)   $ timestamp "This would happen at 15 sec"
--     timestamp "And this happens immediately after start"
-- @
schedule
    :: (Monad m, HasCap Timed caps)
    => RelativeToNow -> CapsT caps m () -> CapsT caps m ()
schedule time action = fork_ $ invoke time action

-- | Executes an action at specified time in current thread.
-- Use `after` to specify relative virtual time (counting from now),
-- and `at` for absolute one.
--
-- @
-- invoke time action ≡ wait time >> action
-- @
--
-- @
-- example :: (MonadTimed m, MonadIO m) => CapsT caps m ()
-- example = do
--     wait (for 10 sec)
--     invoke (after 3 sec) $ timestamp "This would happen at 13 sec"
--     invoke (after 3 sec) $ timestamp "This would happen at 16 sec"
--     invoke (at 20 sec)   $ timestamp "This would happen at 20 sec"
--     timestamp "This also happens at 20 sec"
-- @
invoke :: (Monad m, HasCap Timed caps) => RelativeToNow -> CapsT caps m a -> CapsT caps m a
invoke time action = wait time >> action

-- | Prints current virtual time. For debug purposes.
--
-- >>> runTimedT $ wait (for 1 mcs) >> timestamp "Look current time here"
-- [1µs] Look current time here
timestamp :: (HasCap Timed caps, MonadIO m) => String -> CapsT caps m ()
timestamp msg = virtualTime >>= \time -> liftIO . putStrLn $
    concat [ "[", show time, "] ", msg ]

-- | Similar to `fork`, but doesn't return a result.
fork_ :: (Monad m, HasCap Timed caps) => CapsT caps m () -> CapsT caps m ()
fork_ = void . fork

-- | Creates a thread, which works for specified amount of time, and then gets
-- `killThread`ed.
-- Use `for` to specify relative virtual time (counting from now),
-- and `till` for absolute one.
work :: (Monad m, HasCap Timed caps) => RelativeToNow -> CapsT caps m () -> CapsT caps m ()
work rel act = fork act >>= schedule rel . killThread

-- | Arises `ThreadKilled` exception in specified thread
killThread :: HasCap Timed caps => ThreadId -> CapsT caps m ()
killThread = flip throwTo ThreadKilled

-- | Converts a specified time to `Microsecond`.
mcs, ms, sec, minute, hour :: Int -> Microsecond
mcs    = fromMicroseconds . fromIntegral
ms     = fromMicroseconds . fromIntegral . (*) 1000
sec    = fromMicroseconds . fromIntegral . (*) 1000000
minute = fromMicroseconds . fromIntegral . (*) 60000000
hour   = fromMicroseconds . fromIntegral . (*) 3600000000

-- | Converts a specified fractional time to `Microsecond`.
mcs', ms', sec', minute', hour' :: Double -> Microsecond
mcs'    = fromMicroseconds . round
ms'     = fromMicroseconds . round . (*) 1000
sec'    = fromMicroseconds . round . (*) 1000000
minute' = fromMicroseconds . round . (*) 60000000
hour'   = fromMicroseconds . round . (*) 3600000000

-- $timespec
-- Following functions are used together with time-controlling functions
-- (`wait`, `invoke` and others) and serve for two reasons:
--
-- (1) Defines, whether time is counted from /origin point/ or
-- current time point.
--
-- (2) Allow different ways to specify time
-- (see <./Control-TimeWarp-Timed-MonadTimed.html#timeacc Time accumulators>)

at, till :: TimeAccR t => t
-- | Defines `RelativeToNow`, which refers to time point determined by specified
-- virtual time.
-- Supposed to be used with `wait` and `work`.
till = till' 0
-- | Synonym to `till`. Supposed to be used with `invoke` and `schedule`.
at   = till' 0

after, for :: TimeAccR t => t
-- | Defines `RelativeToNow`, which refers to time point in specified time after
-- current time point.
-- Supposed to be used with `wait` and `work`.
for   = for' 0
-- | Synonym to `for`. Supposed to be used with `invoke` and `schedule`.
after = for' 0

-- | Refers to current time point.
--
-- >>> runTimedT $ invoke now $ timestamp ""
-- [0µs]
now :: RelativeToNow
now = id

-- | Counts time since outer monad layer was unwrapped.
--
-- @
-- example :: (MonadTimed m, MonadIO m) => CapsT caps m ()
-- example = do
--     wait (for 10 sec)
--     timer <- startTimer
--     wait (for 5 ms)
--     passedTime <- timer
--     liftIO . print $ passedTime
-- @
--
-- >>> runTimedT example
-- 5000µs
startTimer :: (Monad m, HasCap Timed caps) => CapsT caps m (CapsT caps m Microsecond)
startTimer = do
    start <- virtualTime
    return $ subtract start <$> virtualTime

-- | Returns a time in microseconds.
--
-- >>> print $ interval 1 sec
-- 1000000µs
interval :: TimeAccM t => t
interval = interval' 0

-- | Synonym to `interval`. May be more preferable in some situations.
timepoint :: TimeAccM t => t
timepoint = interval

-- * Time accumulators
-- $timeacc
-- #timeacc#
-- Time accumulators allow to specify time in pretty complicated ways.
--
-- * Some of them can accept `TimeUnit`, which fully defines result.
--
-- @
-- for (5 :: Minute)
-- @
--
-- * They can accept several numbers with time measures, which would be sumarized.
--
-- @
-- for 1 minute 15 sec 10 mcs
-- for 1.2 minute'
-- @

-- | Time accumulator, which evaluates to `RelativeToNow`.
-- It's implementation is intentionally not visible from this module.
class TimeAccR t where
    till' :: Microsecond -> t
    for'  :: Microsecond -> t

instance TimeAccR RelativeToNow where
    till' = const
    for'  = (+)

instance (a ~ b, TimeAccR t) => TimeAccR (a -> (b -> Microsecond) -> t) where
    till' acc t f = till' $ f t + acc
    for'  acc t f = for'  $ f t + acc

instance TimeUnit t => TimeAccR (t -> RelativeToNow) where
    till' acc t _   = acc + convertUnit t
    for'  acc t cur = acc + convertUnit t + cur

-- | Time accumulator, which evaluates to `Microsecond`.
-- It's implementation is intentionally not visible from this module.
class TimeAccM t where
    interval' :: Microsecond -> t

instance TimeAccM Microsecond where
    interval' = id

instance (a ~ b, TimeAccM t) => TimeAccM (a -> (b -> Microsecond) -> t) where
    interval' acc t f = interval' $ f t + acc
