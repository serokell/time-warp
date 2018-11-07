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
       , TimedTOptions (..)
       , runTimedT
       , runTimedTExt
       , defaultLoggerName
       , pureTimedCap
       ) where

import Control.Applicative ((<|>))
import Control.Exception.Base (AsyncException (ThreadKilled), Exception (fromException),
                               SomeException (..))

import Control.Lens (at, makeLenses, use, view, (%=), (%~), (&), (.=), (.~), (<&>), (<<+=), (<<.=),
                     (^.))
import Control.Monad (unless, void)
import Control.Monad.Catch (Handler (..), MonadCatch, MonadMask, MonadThrow, catch, catchAll,
                            catches, finally, mask, throwM, try, uninterruptibleMask)
import Control.Monad.Cont (ContT (..), runContT)
import Control.Monad.Fix (fix)
import Control.Monad.Loops (whileM_)
import Control.Monad.Reader (ReaderT (..), ask, local, runReaderT)
import Control.Monad.State (MonadState (get, put, state), StateT, evalStateT)
import Control.Monad.Trans (MonadIO, MonadTrans, lift, liftIO)
import Data.Default (Default (..))
import Data.Function (on)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (foldl')
import Data.Ord (comparing)
import Formatting (sformat, shown, (%))
import Monad.Capabilities (CapImpl (..))

import qualified Data.Map as M
import qualified Data.PQueue.Min as PQ
import Safe (fromJustNote)

import Control.TimeWarp.Logging (LoggerName, WithNamedLogger (..), logDebug, logWarning)
import Control.TimeWarp.Timed.MonadTimed (Microsecond, MonadTimedError (MTTimeoutError),
                                          ThreadId (..), Timed (..), for, mcs)

-- Summary, `TimedT` (implementation of emulation mode) consists of several
-- layers (from outer to inner):
-- * ReaderT ThreadCtx  -- keeps tied-to-thread information
-- * ContT              -- allows to extract not-yet-executed part of thread
                        -- to perform it later
-- * StateT Scenario    -- keeps global information of emulation

-- | Analogy to `Control.Concurrent.ThreadId` for emulation.
newtype PureThreadId = PureThreadId { unPureThreadId :: Integer }
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
      -- | Whether main thread has terminated
    , _mainThreadDone  :: Bool
    }

$(makeLenses ''Scenario)

emptyScenario :: Scenario m c
emptyScenario =
    Scenario
    { _events = PQ.empty
    , _curTime = 0
    , _asyncExceptions = M.empty
    , _threadsCounter = 0
    , _mainThreadDone = False
    }

data TimedTOptions = TimedTOptions
    { -- | Finish execution on main thread termination even if there are other
      -- threads running.
      shutdownOnMainEnd :: Bool
    } deriving (Show)

instance Default TimedTOptions where
    def =
        TimedTOptions
        { shutdownOnMainEnd = False
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
launchTimedT :: (MonadIO m, MonadCatch m) => TimedTOptions -> TimedT m () -> m ()
launchTimedT options timed = getTimedT $ do
    -- execute first action (main thread)
    do
        let markMainTerminated = TimedT $ mainThreadDone .= True
        ctx <- mainThreadCtx
        runInSandbox ctx (timed `finally` markMainTerminated)

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
    notDone = TimedT $ do
        hasThreadsRunning <- not . PQ.null <$> use events
        mainTerminated <- use mainThreadDone
        return $ and
            [ hasThreadsRunning
            , not (mainTerminated && shutdownOnMainEnd options)
            ]

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
runTimedT = runTimedTExt def

-- | Similar to 'runTimedT', allows to provide options.
runTimedTExt
    :: (MonadIO m, MonadCatch m)
    => TimedTOptions -> TimedT m a -> m a
runTimedTExt options timed = do
    -- use `launchTimedT`, extracting result
    ref <- liftIO $ newIORef Nothing
    launchTimedT options $ do
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

pureTimedCap :: (MonadIO m, MonadCatch m) => CapImpl Timed '[] (TimedT m)
pureTimedCap = CapImpl $ fix $ \Timed{..} -> Timed
    { _virtualTime = lift . TimedT $ use curTime
    , _currentTime = _virtualTime
    -- Take note, created thread may be killed by async exception
    -- only when it calls "wait"
    , _fork = \act -> do
        -- just put new thread to event queue
        _timestamp <- _virtualTime
        tid <- lift getNextThreadId
        logName    <- getLoggerName
        caps <- ask
        let _threadCtx =
                ThreadCtx
                { _threadId   = tid
                , _handlers   = []   -- top-level exceptions are caught below
                , _loggerName = logName
                }
            _action = flip runReaderT caps $
                      act `catch` threadKilledNotifier
        lift . TimedT $ events %= PQ.insert Event {..}
        _wait $ for 1 mcs  -- real `forkIO` seems to yield execution
                           -- to newly created thread
        return $ EmuThreadId (unPureThreadId tid)
    , _wait = \relativeToNow -> do
        cur <- _virtualTime
        ctx <- lift $ TimedT ask
        let event following =
                Event
                { _threadCtx = ctx
                , _timestamp = max cur (relativeToNow cur)
                , _action = wrapCore following
                }
        -- grab our continuation, put it to event queue
        -- and finish execution
        lift . TimedT . lift . ContT $
            \c -> events %= PQ.insert (event $ c ())
    , _myThreadId = fmap (EmuThreadId . unPureThreadId) $
                    lift $ TimedT $ view threadId
    , _throwTo = \case
        RealThreadId _ ->
            error "throwTo: real and pure 'Timed' are mixed up"
        EmuThreadId (PureThreadId -> tid) -> \e -> lift . TimedT $ do
            -- wake up thread
            time <- use curTime
            let modifyRequired event =
                    if event ^. threadCtx . threadId == tid
                    then event & timestamp .~ time
                    else event
            events %= PQ.fromList . map modifyRequired . PQ.toList
            -- throw (TODO: make it more efficient)
            asyncExceptions . at tid %= (<|> Just (SomeException e))

    , _timeout = \t action' -> do
        pid  <- _myThreadId
        done <- liftIO $ newIORef False
        void . _fork $ do
            _wait (for t)
            done' <- liftIO (readIORef done)
            unless done' $
                _throwTo pid $ MTTimeoutError "Timeout exceeded"
        action' `finally` liftIO (writeIORef done True)
    }

-- | Name which is used by logger (see `WithNamedLogger`) if no other one was specified.
defaultLoggerName :: LoggerName
defaultLoggerName = "emulation"
