{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE Rank2Types             #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE ViewPatterns           #-}

-- | This module defines typeclass `MonadTimed` with basic functions
-- to work with time and threads.
module Control.TimeWarp.Timed.MonadTimed
    ( -- * Typeclass with basic functions
      MonadTimed (..)
    , RelativeToNow
      -- * Helper functions
      -- | NOTE: do we ever need `schedule` and `invoke`? These functions are 
      -- not complex, and aren't used in production. Just provide another funny
      -- syntax like @invoke $ at 5 sec@
    , schedule, invoke, timestamp, fork_, killThread
    , startTimer
    , workWhile, work, workWhileMVarEmpty, workWhileMVarEmpty'
      -- ** Time measures
      -- | NOTE: do we need @hour@ measure?
    , minute , sec , ms , mcs, tu
    , minute', sec', ms', mcs'
      -- ** Time specifiers
      -- $timespec
    , after, for, at, till, now
    , during, upto
    , interval
      -- * Time types
      -- | Re-export of `Data.Time.Units.Microsecond`
    , Microsecond
      -- | Re-export of `Data.Time.Units.Millisecond`
    , Millisecond
      -- | Re-export of `Data.Time.Units.Second`
    , Second
      -- | Re-export of `Data.Time.Units.Minute`
    , Minute
      -- * Exceptions
    , MonadTimedError (..)
    ) where

import           Control.Concurrent.MVar (MVar, isEmptyMVar)
import           Control.Exception       (Exception (..),
                                          AsyncException (ThreadKilled))
import           Control.Monad           (void)
import           Control.Monad.Catch     (MonadThrow)
import           Control.Monad.Loops     (whileM)
import           Control.Monad.Reader    (ReaderT (..), ask, runReaderT)
import           Control.Monad.State     (StateT, evalStateT, get)
import           Control.Monad.Trans     (MonadIO, lift, liftIO)

import           Data.IORef              (newIORef, readIORef, writeIORef)
import           Data.Monoid             ((<>))
import           Data.Text               (Text)
import           Data.Text.Buildable     (Buildable (build))
import           Data.Time.Units         (Microsecond, Millisecond, Minute,
                                          Second, TimeUnit (..), convertUnit)
import           Data.Typeable           (Typeable)

-- | Defines some time point basing on current time point, relatively to now.
-- That is, if current virtual time is 10µs, @const 15@ would refer to
-- 10 + 15 = 25µs, while @(-) 15@ refers to 10 + (15 - 10) = 15µs.
--
-- (NOTE: calculating time relativelly to now seems pretty inconvinient,
-- if someone agrees I'll fix it).
type RelativeToNow = Microsecond -> Microsecond

-- | Is arisen on call of `timeout` if action hasn't executed in time.
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
--     * when defining instance of MonadTrans for a monad transformer,
-- information stored inside this transformer should be tied to thread, and
-- get cloned on `fork`s. #monads-above#
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


class MonadThrow m => MonadTimed m where
    -- | Type of thread identifier.
    type ThreadId m :: *

    -- | Acquires virtual time.
    localTime :: m Microsecond

    -- | Waits for specified amount of time.
    --
    -- Use `for` to specify relative virtual time, and `till` for absolute one.
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

    -- | Throws an TimeoutError exception
    -- if running an action exceeds running time.
    -- TODO: eliminate it when `Mvar` appears on the scene
    timeout :: Microsecond -> m a -> m a

-- | Executes an action somewhere in future in another thread.
--
-- Use `after` to specify relative virtual time, and `at` for absolute one.
--
-- @
-- schedule time action = fork_ $ wait time >> action
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
--
-- @
-- invoke time action = wait time >> action
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
timestamp msg = localTime >>= \time -> liftIO . putStrLn $ concat
    [ "["
    , show time
    , "] "
    , msg
    ]

-- | Forks a temporal thread, which exists until preficate evaluates to False.
-- Another servant thread is used to periodically check that condition,
-- beware of overhead.
{-# DEPRECATED workWhile "May give sagnificant overhead, use with caution" #-}
workWhile :: (MonadIO m, MonadTimed m) => m Bool -> m () -> m ()
workWhile = workWhile' $ interval 10 sec

-- | Like `workWhile`, but also allows to specify delay between checks.
{-# DEPRECATED workWhile' "May give sagnificant overhead, use with caution" #-}
workWhile' :: (MonadIO m, MonadTimed m) => Microsecond -> m Bool -> m () -> m ()
workWhile' checkDelay cond action = do
    working <- liftIO $ newIORef True
    tid     <- fork $ action >> liftIO (writeIORef working False)
    fork_ $ do
        _ <- whileM ((&&) <$> cond <*> liftIO (readIORef working)) $
            wait $ for checkDelay mcs
        killThread tid

-- | Like workWhile, unwraps first layer of monad immediatelly
--   and then checks predicate periocially.
{-# DEPRECATED work "May give sagnificant overhead, use with caution" #-}
work :: (MonadIO m, MonadTimed m) => TwoLayers m Bool -> m () -> m ()
work (getTL -> predicate) action = predicate >>= \p -> workWhile p action

-- | Forks temporary thread which works while MVar is empty.
-- Another servant thread is used to periodically check the state of MVar,
-- beware of overhead.
{-# DEPRECATED workWhileMVarEmpty "May give sagnificant overhead, use with caution" #-}
workWhileMVarEmpty
    :: (MonadTimed m, MonadIO m)
    => MVar a -> m () -> m ()
workWhileMVarEmpty v = workWhile (liftIO . isEmptyMVar $ v)

-- | Like `workWhileMVarEmpty`, but allows to specify delay between checks.
{-# DEPRECATED workWhileMVarEmpty' "May give sagnificant overhead, use with caution" #-}
workWhileMVarEmpty'
    :: (MonadTimed m, MonadIO m)
    => Microsecond -> MVar a -> m () -> m ()
workWhileMVarEmpty' delay v = workWhile' delay (liftIO . isEmptyMVar $ v)

-- | Similar to `fork`, but doesn't return a result.
fork_ :: MonadTimed m => m () -> m ()
fork_ = void . fork

-- | Arises `ThreadKilled` exception in specified thread
killThread :: MonadTimed m => ThreadId m -> m ()
killThread = flip throwTo ThreadKilled

instance MonadTimed m => MonadTimed (ReaderT r m) where
    type ThreadId (ReaderT r m) = ThreadId m

    localTime = lift localTime

    wait = lift . wait

    fork m = lift . fork . runReaderT m =<< ask

    myThreadId = lift myThreadId

    throwTo tid = lift . throwTo tid

    timeout t m = lift . timeout t . runReaderT m =<< ask

instance MonadTimed m => MonadTimed (StateT s m) where
    type ThreadId (StateT s m) = ThreadId m

    localTime = lift localTime

    wait = lift . wait

    fork m = lift . fork . evalStateT m =<< get

    myThreadId = lift myThreadId

    throwTo tid = lift . throwTo tid

    timeout t m = lift . timeout t . evalStateT m =<< get

-- | Converts a specified time unit to `Microsecond`.
mcs :: Microsecond -> Microsecond
mcs = convertUnit

-- | Converts a specified time unit to `Microsecond`.
ms :: Millisecond -> Microsecond
ms = convertUnit

-- | Converts a specified time unit to `Microsecond`.
sec :: Second -> Microsecond
sec = convertUnit

-- | Converts a specified time unit to `Microsecond`.
minute :: Minute -> Microsecond
minute = convertUnit

-- | Converts a specified fractional time to `Microsecond`.
mcs', ms', sec', minute' :: Double -> Microsecond
mcs'    = fromMicroseconds . round
ms'     = fromMicroseconds . round . (*) 1000
sec'    = fromMicroseconds . round . (*) 1000000
minute' = fromMicroseconds . round . (*) 60000000

-- | Measure for `TimeUnit`s.
tu :: TimeUnit t => t -> Microsecond
tu = convertUnit

-- $timespec
-- Following functions are used together with time-controlling functions
-- (`wait`, `invoke` and others) and serve for two reasons:
--
-- (1) Defines, whether time is counted from /origin point/ or
-- current time point.
--
-- (2) Accumulate following time parts, allowing to write something like
--
-- @
-- for 1 minute 2 sec 3 mcs
-- @
--
-- Order of time parts is irrelevant.
--

-- | Time point by given virtual time.
at, till :: TimeAcc1 t => t
at   = at' 0
till = at' 0

-- | Time point relative to current time.
after, for :: TimeAcc1 t => t
after = after' 0
for   = after' 0

-- | Current time point.
--
-- >>> runTimedT $ invoke now $ timestamp ""
-- [0µs]
now :: RelativeToNow
now = const 0

-- | Returns whether specified delay has passed
--   (timer starts when first monad layer is unwrapped).
during :: TimeAcc2 t => t
during = during' 0

-- | Returns whether specified time point has passed.
upto :: TimeAcc2 t => t
upto = upto' 0

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
    start <- localTime
    return $ subtract start <$> localTime

-- | Returns a time in microseconds
--
-- >>> print $ interval 1 sec
-- 1000000µs
interval :: TimeAcc3 t => t
interval = interval' 0


-- plenty of black magic
class TimeAcc1 t where
    at'    :: Microsecond -> t
    after' :: Microsecond -> t

instance TimeAcc1 RelativeToNow where
    at'    = (-)
    after' = const

instance (a ~ b, TimeAcc1 t) => TimeAcc1 (a -> (b -> Microsecond) -> t) where
    at'    acc t f = at'    $ f t + acc
    after' acc t f = after' $ f t + acc

-- without this newtype TimeAcc2 doesn't work - overlapping instances
newtype TwoLayers m a = TwoLayers { getTL :: m (m a) }

class TimeAcc2 t where
    during' :: Microsecond -> t
    upto'   :: Microsecond -> t

instance MonadTimed m => TimeAcc2 (TwoLayers m Bool) where
    during' time = TwoLayers $ do
        end <- (time + ) <$> localTime
        return $ (end > ) <$> localTime

    upto' time = TwoLayers . return $ (time > ) <$> localTime

instance (a ~ b, TimeAcc2 t) => TimeAcc2 (a -> (b -> Microsecond) -> t) where
    during' acc t f = during' $ f t + acc
    upto'   acc t f = upto'   $ f t + acc


class TimeAcc3 t where
    interval' :: Microsecond -> t

instance TimeAcc3 Microsecond where
    interval' = id

instance (a ~ b, TimeAcc3 t) => TimeAcc3 (a -> (b -> Microsecond) -> t) where
    interval' acc t f = interval' $ f t + acc
