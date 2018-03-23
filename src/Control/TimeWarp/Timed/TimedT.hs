{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE UndecidableInstances      #-}

-- |
-- Module      : Control.TimeWarp.Timed.TimedT
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module contains pure implementation of MonadTimed.
module Control.TimeWarp.Timed.TimedT
       ( TimedT
       , PureThreadId
       , runTimedT
       , defaultLoggerName
       ) where

import           Control.Applicative               ((<|>))
import           Control.Exception.Base            (AsyncException (ThreadKilled),
                                                    Exception (fromException),
                                                    SomeException (..))

import           Control.Lens                      (at, makeLenses, use, view, (%=), (%~),
                                                    (&), (.=), (.~), (<&>), (<<+=),
                                                    (<<.=), (^.))
import           Control.Monad                     (unless, void)
import           Control.Monad.Catch               (Handler (..), MonadCatch, MonadMask,
                                                    MonadThrow, catch, catchAll, catches,
                                                    finally, mask, throwM, try,
                                                    uninterruptibleMask)
import           Control.Monad.Cont                (ContT (..), runContT)
import           Control.Monad.Loops               (whileM_)
import           Control.Monad.Reader              (ReaderT (..), ask, local, runReaderT)
import           Control.Monad.State               (MonadState (get, put, state), StateT,
                                                    evalStateT)
import           Control.Monad.Trans               (MonadIO, MonadTrans, lift, liftIO)
import           Data.Function                     (on)
import           Data.IORef                        (newIORef, readIORef, writeIORef)
import           Data.List                         (foldl')
import           Data.Ord                          (comparing)
import           Formatting                        (sformat, shown, (%))

import qualified Data.Map                          as M
import qualified Data.PQueue.Min                   as PQ
import           Safe                              (fromJustNote)

import           Control.TimeWarp.Logging          (LoggerName, WithNamedLogger (..),
                                                    logDebug, logWarning)
import           Control.TimeWarp.Timed.MonadTimed (Microsecond, MonadTimed (..),
                                                    MonadTimedError (MTTimeoutError),
                                                    ThreadId, after, for, mcs, schedule,
                                                    timeout, virtualTime)

-- Summary, `TimedT` (implementation of emulation mode) consists of several
-- layers (from outer to inner):
-- * ReaderT ThreadCtx  -- keeps tied-to-thread information
-- * ContT              -- allows to extract not-yet-executed part of thread
                        -- to perform it later
-- * StateT Scenario    -- keeps global information of emulation

-- | Analogy to `Control.Concurrent.ThreadId` for emulation.
newtype PureThreadId = PureThreadId Integer
    deriving (Eq, Ord)

instance Show PureThreadId where
    show (PureThreadId tid) = "PureThreadId " ++ show tid

-- | Private context for each pure thread
data ThreadCtx c = ThreadCtx
    { -- | Thread id
      _threadId   :: PureThreadId
      -- | Exception handlers stack. First is original handler,
      --   second is for continuation handler
    , _handlers   :: [(Handler c (), Handler c ())]
      -- | Logger name for `WithNamedLogger` instance
    , _loggerName :: LoggerName
    }

$(makeLenses ''ThreadCtx)

-- | Timestamped action
data Event m c = Event
    { _timestamp :: Microsecond
    , _action    :: m ()
    , _threadCtx :: ThreadCtx c
    }

$(makeLenses ''Event)

instance Eq (Event m c) where
    (==) = (==) `on` _timestamp

instance Ord (Event m c) where
    compare = comparing _timestamp

-- | Overall state for MonadTimed
data Scenario m c = Scenario
    { -- | Set of sleeping threads
      _events          :: PQ.MinQueue (Event m c)
      -- | Current virtual time
    , _curTime         :: Microsecond
      -- | For each thread, exception which has been thrown to it (if any has)
    , _asyncExceptions :: M.Map PureThreadId SomeException
      -- | Number of created threads ever
    , _threadsCounter  :: Integer
    }

$(makeLenses ''Scenario)

emptyScenario :: Scenario m c
emptyScenario =
    Scenario
    { _events = PQ.empty
    , _curTime = 0
    , _asyncExceptions = M.empty
    , _threadsCounter = 0
    }

-- | Heart of TimedT monad
newtype Core m a = Core
    { getCore :: StateT (Scenario (TimedT m) (Core m)) m a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadThrow,
               MonadCatch, MonadMask,
               MonadState (Scenario (TimedT m) (Core m)))

instance MonadTrans Core where
    lift = Core . lift

-- Threads are emulated, whole execution takes place in a single thread.
-- This allows to execute whole scenarios on the spot.
--
-- Each action is considered 0-cost in performance, the only way to change
-- current virtual time is to call `wait` or derived function.
--
-- Note, that monad inside TimedT transformer is shared between all threads.
newtype TimedT m a = TimedT
    { unwrapTimedT :: ReaderT (ThreadCtx (Core m))
                        ( ContT ()
                          ( Core m )
                        ) a
    } deriving (Functor, Applicative, Monad, MonadIO)

-- | When non-main thread dies from uncaught exception, this is reported via
-- logger (see `WithNamedLogger`). `ThreadKilled` exception is reported with
-- `Control.TimeWarp.Logging.Debug` severity, and other exceptions with
-- `Control.TimeWarp.Logging.Warn` severity.
-- Uncaught exception in main thread (the one isn't produced by `fork`)
-- is propagaded outside of the monad.
instance MonadThrow m => MonadThrow (TimedT m) where
    -- docs for derived instance declarations are not supported yet :(
    throwM = TimedT . throwM

instance MonadTrans TimedT where
    lift = TimedT . lift . lift . lift

instance MonadState s m => MonadState s (TimedT m) where
    get = lift get
    put = lift . put
    state = lift . state

instance WithNamedLogger (TimedT m) where
    getLoggerName = TimedT $ view loggerName

    modifyLoggerName how = TimedT . local (loggerName %~ how) . unwrapTimedT

newtype ContException = ContException SomeException
    deriving (Show)

instance Exception ContException

instance (MonadCatch m) => MonadCatch (TimedT m) where
    catch m handler =
        TimedT $
        ReaderT $
        \r ->
            ContT $
            -- Types allow us to catch only from (m + its continuation).
            -- Thus, we should avoid handling exception from continuation.
            -- It's achieved by handling any exception from continuation
            -- and rethrowing it being wrapped into ContException.
            -- Then, any catch handler should first check for ContException.
            -- If it's caught, rethrow exception inside ContException,
            -- otherwise handle any possible normal exception
            \c ->
                let safeCont x = c x `catchAll` (throwM . ContException)
                    r' = r & handlers %~ (:) (Handler handler', contHandler)
                    act = unwrapCore' r' $ m >>= wrapCore . safeCont
                    handler' e = unwrapCore' r $ handler e >>= wrapCore . c
                in  act `catches` [contHandler, Handler handler']

contHandler :: MonadThrow m => Handler m ()
contHandler = Handler $ \(ContException e) -> throwM e

-- | This instance is incorrect, i.e. `mask` and `uninterruptibleMask` do
-- nothing for now.
instance (MonadIO m, MonadCatch m) => MonadMask (TimedT m) where
    mask a = a id
    uninterruptibleMask = mask

wrapCore :: Monad m => Core m a -> TimedT m a
wrapCore = TimedT . lift . lift

unwrapCore :: ThreadCtx (Core m)
           -> (a -> Core m ())
           -> TimedT m a
           -> Core m ()
unwrapCore r c = flip runContT c
               . flip runReaderT r
               . unwrapTimedT

unwrapCore' :: Monad m => ThreadCtx (Core m) -> TimedT m () -> Core m ()
unwrapCore' r = unwrapCore r return

getTimedT :: Monad m => TimedT m a -> m ()
getTimedT t = flip evalStateT emptyScenario
            $ getCore
            $ unwrapCore vacuumCtx (void . return) t
  where
    vacuumCtx = error "Access to thread context from nowhere"

-- | Launches all the machinery of emulation.
launchTimedT :: (MonadIO m, MonadCatch m) => TimedT m () -> m ()
launchTimedT timed = getTimedT $ do
    -- execute first action (main thread)
    mainThreadCtx >>= flip runInSandbox timed
    -- event loop
    whileM_ notDone $ do
        -- take next awaiting thread
        nextEv <- wrapCore . Core $ do
            (ev, evs') <- fromJustNote "Suddenly no more events" . PQ.minView
                            <$> use events
            events .= evs'
            return ev
        -- rewind current time
        TimedT $ curTime .= nextEv ^. timestamp
        -- get some thread info
        let ctx = nextEv ^. threadCtx
            tid = ctx ^. threadId
        -- extract possible exception thrown
        maybeAsyncExc <- TimedT $ asyncExceptions . at tid <<.= Nothing

        let act = do
                -- die if received async exception
                mapM_ throwInnard maybeAsyncExc
                -- execute thread
                runInSandbox ctx (nextEv ^. action)
            -- catch with handlers from handlers stack
            -- `catch` which is performed in instance MonadCatch is not enough,
            -- because on `wait` `catch`'s scope finishes, we need to catch
            -- again here
        wrapCore $ (unwrapCore' ctx act) `catchesSeq` (ctx ^. handlers)

  where
    notDone :: Monad m => TimedT m Bool
    notDone = not . PQ.null <$> TimedT (use events)

    -- put empty continuation to an action (not our own!)
    runInSandbox r = wrapCore . unwrapCore' r

    mainThreadCtx = getNextThreadId <&>
        \tid ->
            ThreadCtx
            { _threadId   = tid
            , _handlers   = [( Handler throwInnard
                           , contHandler
                           )]
            , _loggerName = defaultLoggerName
            }

    -- Apply all handlers from stack.
    -- In each layer (pair of handlers), ContException should be handled first.
    catchesSeq = foldl' $ \act (h, hc) -> act `catches` [hc, h]

    throwInnard (SomeException e) = throwM e

getNextThreadId :: Monad m => TimedT m PureThreadId
getNextThreadId = TimedT . fmap PureThreadId $ threadsCounter <<+= 1

-- | Launches the scenario emulating threads and time.
-- Finishes when no more active threads remain.
runTimedT
    :: (MonadIO m, MonadCatch m)
    => TimedT m a -> m a
runTimedT timed = do
    -- use `launchTimedT`, extracting result
    ref <- liftIO $ newIORef Nothing
    launchTimedT $ do
        m <- try timed
        liftIO . writeIORef ref . Just $ m
    res :: Either SomeException a <- fromJustNote "runTimedT: no result"
                                        <$> liftIO (readIORef ref)
    either throwM return res

isThreadKilled :: SomeException -> Bool
isThreadKilled = maybe False (== ThreadKilled) . fromException

threadKilledNotifier
    :: (MonadIO m, WithNamedLogger m)
    => SomeException -> m ()
threadKilledNotifier e
    | isThreadKilled e = logDebug msg
    | otherwise = logWarning msg
  where
    msg = sformat ("Thread killed by exception: " % shown) e

type instance ThreadId (TimedT m) = PureThreadId

instance (MonadIO m, MonadThrow m, MonadCatch m) =>
         MonadTimed (TimedT m) where
    virtualTime = TimedT $ use curTime
    currentTime = virtualTime
    -- | Take note, created thread may be killed by async exception
    --   only when it calls "wait"
    fork act
         -- just put new thread to event queue
     = do
        _timestamp <- virtualTime
        tid        <- getNextThreadId
        logName    <- getLoggerName
        let _threadCtx =
                ThreadCtx
                { _threadId   = tid
                , _handlers   = []   -- top-level exceptions are caught below
                , _loggerName = logName
                }
            _action = act `catch` threadKilledNotifier
        TimedT $ events %= PQ.insert Event {..}
        wait $ for 1 mcs  -- real `forkIO` seems to yield execution
                          -- to newly created thread
        return tid
    wait relativeToNow = do
        cur <- virtualTime
        ctx <- TimedT ask
        let event following =
                Event
                { _threadCtx = ctx
                , _timestamp = max cur (relativeToNow cur)
                , _action = wrapCore following
                }
        -- grab our continuation, put it to event queue
        -- and finish execution
        TimedT . lift . ContT $
            \c -> events %= PQ.insert (event $ c ())
    myThreadId = TimedT $ view threadId
    throwTo tid e = do
        wakeUpThread
        TimedT $ asyncExceptions . at tid %= (<|> Just (SomeException e))
      where
        -- TODO: make more efficient
        wakeUpThread = TimedT $ do
            time <- use curTime
            let modifyRequired event =
                    if event ^. threadCtx . threadId == tid
                    then event & timestamp .~ time
                    else event
            events %= PQ.fromList . map modifyRequired . PQ.toList

    timeout t action' = do
        pid  <- myThreadId
        done <- liftIO $ newIORef False
        schedule (after t) $
            (liftIO (readIORef done) >>=) . flip unless $
                throwTo pid $ MTTimeoutError "Timeout exceeded"
        action' `finally` liftIO (writeIORef done True)

-- | Name which is used by logger (see `WithNamedLogger`) if no other one was specified.
defaultLoggerName :: LoggerName
defaultLoggerName = "emulation"
