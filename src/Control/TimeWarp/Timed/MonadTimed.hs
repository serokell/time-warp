{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}

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
      MonadTimed (..)
    , ThreadId
    , RelativeToNow
      -- * Helper functions
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

import           Control.Exception        (AsyncException (ThreadKilled), Exception (..))
import           Control.Monad            (void)
import           Control.Monad.Catch      (MonadThrow)
import           Control.Monad.Reader     (ReaderT (..), ask, runReaderT)
import           Control.Monad.State      (StateT, evalStateT, get)
import           Control.Monad.Trans      (MonadIO, lift, liftIO)

import           Data.Monoid              ((<>))
import           Data.Text                (Text)
import           Data.Text.Buildable      (Buildable (build))
import           Data.Time.Units          (Microsecond, Millisecond, Minute, Second,
                                           TimeUnit (..), convertUnit)
import           Data.Typeable            (Typeable)

import           Control.TimeWarp.Logging (LoggerNameBox (..))

-- | Defines some time point basing on current virtual time.
type RelativeToNow = Microsecond -> Microsecond

-- | Is arisen on call of `timeout` if action wasn't executed in time.
data MonadTimedError
    = MTTimeoutError Text
    deriving (Show, Typeable)

instance Exception MonadTimedError

instance Buildable MonadTimedError where
    build (MTTimeoutError t) = "timeout error: " <> build t

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


class MonadThrow m => MonadTimed m where
    -- | Acquires virtual time.
    virtualTime :: m Microsecond

    -- | Acquires (pseudo-)real time.
    currentTime :: m Microsecond

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
    wait :: RelativeToNow -> m ()

    -- | Creates another thread of execution, with same point of origin.
    fork :: m () -> m (ThreadId m)

    -- | Acquires current thread id.
    myThreadId :: m (ThreadId m)

    -- | Arises specified exception in specified thread.
    throwTo :: Exception e => ThreadId m -> e -> m ()

    -- | Throws a `MTTimeoutError` exception
    -- if running action exceeds specified time.
    timeout :: TimeUnit t => t -> m a -> m a

-- | Type of thread identifier.
type family ThreadId (m :: * -> *) :: *

-- | Executes an action somewhere in future in another thread.
-- Use `after` to specify relative virtual time (counting from now),
-- and `at` for absolute one.
--
-- @
-- schedule time action ≡ fork_ $ wait time >> action
-- @
--
-- @
-- example :: (MonadTimed m, MonadIO m) => m ()
-- example = do
--     wait (for 10 sec)
--     schedule (after 3 sec) $ timestamp "This would happen at 13 sec"
--     schedule (at 15 sec)   $ timestamp "This would happen at 15 sec"
--     timestamp "And this happens immediately after start"
-- @
schedule :: MonadTimed m => RelativeToNow -> m () -> m ()
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
-- example :: (MonadTimed m, MonadIO m) => m ()
-- example = do
--     wait (for 10 sec)
--     invoke (after 3 sec) $ timestamp "This would happen at 13 sec"
--     invoke (after 3 sec) $ timestamp "This would happen at 16 sec"
--     invoke (at 20 sec)   $ timestamp "This would happen at 20 sec"
--     timestamp "This also happens at 20 sec"
-- @
invoke :: MonadTimed m => RelativeToNow -> m a -> m a
invoke time action = wait time >> action

-- | Prints current virtual time. For debug purposes.
--
-- >>> runTimedT $ wait (for 1 mcs) >> timestamp "Look current time here"
-- [1µs] Look current time here
timestamp :: (MonadTimed m, MonadIO m) => String -> m ()
timestamp msg = virtualTime >>= \time -> liftIO . putStrLn $
    concat [ "[", show time, "] ", msg ]

-- | Similar to `fork`, but doesn't return a result.
fork_ :: MonadTimed m => m () -> m ()
fork_ = void . fork

-- | Creates a thread, which works for specified amount of time, and then gets
-- `killThread`ed.
-- Use `for` to specify relative virtual time (counting from now),
-- and `till` for absolute one.
work :: MonadTimed m => RelativeToNow -> m () -> m ()
work rel act = fork act >>= schedule rel . killThread

-- | Arises `ThreadKilled` exception in specified thread
killThread :: MonadTimed m => ThreadId m -> m ()
killThread = flip throwTo ThreadKilled

type instance ThreadId (ReaderT r m) = ThreadId m

instance MonadTimed m => MonadTimed (ReaderT r m) where
    virtualTime = lift virtualTime

    currentTime = lift currentTime

    wait = lift . wait

    fork m = lift . fork . runReaderT m =<< ask

    myThreadId = lift myThreadId

    throwTo tid = lift . throwTo tid

    timeout t m = lift . timeout t . runReaderT m =<< ask

type instance ThreadId (StateT s m) = ThreadId m

instance MonadTimed m => MonadTimed (StateT s m) where
    virtualTime = lift virtualTime

    currentTime = lift currentTime

    wait = lift . wait

    fork m = lift . fork . evalStateT m =<< get

    myThreadId = lift myThreadId

    throwTo tid = lift . throwTo tid

    timeout t m = lift . timeout t . evalStateT m =<< get

type instance ThreadId (LoggerNameBox m) = ThreadId m

deriving instance MonadTimed m => MonadTimed (LoggerNameBox m)

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
-- example :: (MonadTimed m, MonadIO m) => m ()
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
startTimer :: MonadTimed m => m (m Microsecond)
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
