{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE UndecidableInstances      #-}

-- | This module contains pure implementation of MonadTimed.
module Control.TimeWarp.Timed.TimedT
       ( TimedT
       , PureThreadId
       , runTimedT
       , evalTimedT
       ) where

import           Control.Applicative               ((<|>))
import           Control.Exception.Base            (AsyncException (ThreadKilled),
                                                    Exception (fromException),
                                                    SomeException (..))

import           Control.Lens                      (makeLenses, to, use, view, (%=), (%~),
                                                    (&), (+=), (.=), (<&>), (^.))
import           Control.Monad                     (void)
import           Control.Monad.Catch               (Handler (..), MonadCatch, MonadMask,
                                                    MonadThrow, catch, catchAll, catches,
                                                    mask, throwM, try,
                                                    uninterruptibleMask)
import           Control.Monad.Cont                (ContT (..), runContT)
import           Control.Monad.Loops               (whileM_)
import           Control.Monad.Reader              (ReaderT (..), ask, runReaderT)
import           Control.Monad.State               (MonadState (get, put, state), StateT,
                                                    evalStateT)
import           Control.Monad.Trans               (MonadIO, MonadTrans, lift, liftIO)
import           Data.Function                     (on)
import           Data.IORef                        (newIORef, readIORef, writeIORef)
import           Data.List                         (foldl')
import           Data.Maybe                        (fromJust)
import           Data.Ord                          (comparing)
import           Formatting                        (sformat, shown, (%))

import qualified Data.Map                          as M
import qualified Data.PQueue.Min                   as PQ

import           Control.TimeWarp.Logging          (WithNamedLogger (..), logDebug,
                                                    logWarning)
import           Control.TimeWarp.Timed.MonadTimed (Microsecond, Millisecond,
                                                    MonadTimed (..),
                                                    MonadTimedError (MTTimeoutError), for,
                                                    killThread, localTime, mcs,
                                                    timeout)

-- | Analogy to `Control.Concurrent.ThreadId` for emulation
newtype PureThreadId = PureThreadId Integer
    deriving (Eq, Ord)

instance Show PureThreadId where
    show (PureThreadId tid) = "PureThreadId " ++ show tid

-- | Private context for each pure thread
data ThreadCtx c = ThreadCtx
    { -- | Thread id
      _threadId :: PureThreadId
      -- | Exception handlers stack. First is original handler,
      --   second is for continuation handler
    , _handlers :: [(Handler c (), Handler c ())]
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
               MonadCatch, MonadMask)

instance MonadTrans Core where
    lift = Core . lift

deriving instance (Monad m, WithNamedLogger m) => WithNamedLogger (Core m)

instance MonadState s m => MonadState s (Core m) where
    get = lift get
    put = lift . put
    state = lift . state

-- | Pure implementation of MonadTimed.
-- Threads are emulated, whole execution takes place in a single thread.
-- This allows to execute whole scenarios on the spot.
--
-- Each action is considered 0-cost in performance, the only way to change
-- current virtual time is to call `wait` or derived function.
--
-- Note, that monad inside TimedT transformer is shared between all threads.
-- Control.TimeWarp.Timed.MonadTimed/#monads-above
newtype TimedT m a = TimedT
    { unwrapTimedT :: ReaderT (ThreadCtx (Core m)) (ContT () (Core m)) a
    } deriving (Functor, Applicative, Monad, MonadIO)

-- | When thread dies from uncaught exception, this is reported via logger
-- (TODO: which logger?).
-- It doesn't apply to main thread (which is not produced by `fork`),
-- it's exception is propagaded outside of the monad.
instance MonadThrow m => MonadThrow (TimedT m) where
    -- docs for derived instance declarations is not supported yet :(
    throwM = TimedT . throwM

instance MonadTrans TimedT where
    lift = TimedT . lift . lift . lift

instance MonadState s m => MonadState s (TimedT m) where
    get = lift get
    put = lift . put
    state = lift . state

newtype ContException = ContException SomeException
    deriving (Show)

instance Exception ContException

instance (MonadCatch m, MonadIO m) => MonadCatch (TimedT m) where
    catch m handler =
        TimedT $
        ReaderT $
        \r ->
            ContT $
            -- We can catch only from (m + its continuation).
            -- Thus, we should avoid handling exception from continuation.
            -- It's achieved by handling any exception and rethrowing it
            -- wrapped into ContException.
            -- Then, any catch handler should first check for ContException.
            -- If it's thrown, rethrow exception inside ContException,
            -- otherwise handle original exception
            \c ->
                let safeCont x = c x `catchAll` (throwM . ContException)
                    r' = r & handlers %~ (:) (Handler handler', contHandler)
                    act = unwrapCore' r' $ m >>= wrapCore . safeCont
                    handler' e = unwrapCore' r $ handler e >>= wrapCore . c
                in  act `catches` [contHandler, Handler handler']

contHandler :: MonadThrow m => Handler m ()
contHandler = Handler $ \(ContException e) -> throwM e

-- | NOTE: This instance is incorrect
instance (MonadIO m, MonadMask m) => MonadMask (TimedT m) where
    mask a = TimedT $ ReaderT $ \r -> ContT $ \c ->
        mask $ \u -> runContT (runReaderT (unwrapTimedT $ a $ q u) r) c
      where
        q u t = TimedT $ ReaderT $ \r -> ContT $ \c -> u $
            runContT (runReaderT (unwrapTimedT t) r) c

    uninterruptibleMask a = TimedT $ ReaderT $ \r -> ContT $ \c ->
        uninterruptibleMask $
            \u -> runContT (runReaderT (unwrapTimedT $ a $ q u) r) c
      where
        q u t = TimedT $ ReaderT $ \r -> ContT $ \c -> u $
            runContT (runReaderT (unwrapTimedT t) r) c

wrapCore :: Monad m => Core m a -> TimedT m a
wrapCore = TimedT . lift . lift

unwrapCore :: Monad m
           => ThreadCtx (Core m)
           -> (a -> Core m ())
           -> TimedT m a
           -> Core m ()
unwrapCore r c = flip runContT c
               . flip runReaderT r
               . unwrapTimedT

unwrapCore' :: Monad m => ThreadCtx (Core m) -> TimedT m () -> Core m ()
unwrapCore' r = unwrapCore r return

launchTimedT :: Monad m => TimedT m a -> m ()
launchTimedT t = flip evalStateT emptyScenario
               $ getCore
               $ unwrapCore vacuumCtx (void . return) t
  where
    vacuumCtx = error "Access to thread context from nowhere"

-- | Launches the scenario emulating threads and time.
-- Finishes when no more active threads remain.
--
-- Might be slightly more efficient than `evalTimedT`
-- (NOTE: however this is not a significant reason to use the function,
-- suggest excluding it from export list)
runTimedT :: (MonadIO m, MonadCatch m) => TimedT m () -> m ()
runTimedT timed = launchTimedT $ do
    -- execute first action (main thread)
    mainThreadCtx >>= \ctx -> runInSandbox ctx timed
    -- event loop
    whileM_ notDone $ do
        -- take next awaiting thread
        nextEv <- wrapCore . Core $ do
            (ev, evs') <- fromJust . PQ.minView <$> use events
            events .= evs'
            return ev
        -- rewind current time
        wrapCore . Core $ curTime .= nextEv ^. timestamp
        -- get some thread info
        let ctx = nextEv ^. threadCtx
            tid = ctx ^. threadId
        -- extract possible exception thrown to this thread
        maybeAsyncExc <- wrapCore $ Core $ do
            maybeExc <- use $ asyncExceptions . to (M.lookup tid)
            asyncExceptions %= M.delete tid
            return maybeExc

        let -- die if received async exception
            maybeDie = traverse throwInnard maybeAsyncExc
            act      = maybeDie >> runInSandbox ctx (nextEv ^. action)
            -- catch with handlers from handlers stack
            -- `catch` which is performed in instance MonadCatch is not enough,
            -- cause on `wait` `catch`'s scope finishes, we need to catch
            -- again here
        wrapCore $ (unwrapCore' ctx act) `catchesSeq` (ctx ^. handlers)

  where
    notDone :: Monad m => TimedT m Bool
    notDone = wrapCore . Core . use $ events . to (not . PQ.null)

    -- put empty continuation to an action (not our own!)
    runInSandbox r = wrapCore . unwrapCore' r

    mainThreadCtx = getNextThreadId <&>
        \tid ->
            ThreadCtx
            { _threadId = tid
            , _handlers = [( Handler $ \(SomeException e) -> throwM e
                           , Handler $ \(ContException e) -> throwM e
                           )]
            }

    -- Apply all handlers from stack.
    -- In each layer (pair of handlers), ContException should be handled first.
    catchesSeq = foldl' $ \act (h, hc) -> act `catches` [hc, h]

    throwInnard (SomeException e) = throwM e

getNextThreadId :: Monad m => TimedT m PureThreadId
getNextThreadId = wrapCore . Core $ do
    tid <- PureThreadId <$> use threadsCounter
    threadsCounter += 1
    return tid

-- | Just like `runTimedT`, but makes it possible to get a result.
evalTimedT
    :: (MonadIO m, MonadCatch m)
    => TimedT m a -> m a
evalTimedT timed = do
    ref <- liftIO $ newIORef Nothing
    runTimedT $ do
        m <- try timed
        liftIO . writeIORef ref . Just $ m
    res :: Either SomeException a <- fromJust <$> liftIO (readIORef ref)
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

instance (WithNamedLogger m, MonadIO m, MonadThrow m, MonadCatch m) =>
         MonadTimed (TimedT m) where
    type ThreadId (TimedT m) = PureThreadId

    localTime = wrapCore $ Core $ use curTime
    -- | Take note, created thread may be killed by timeout
    --   only when it calls "wait"
    fork _action
         -- just put new thread to an event queue
     = do
        _timestamp <- localTime
        tid <- getNextThreadId
        let _threadCtx =
                ThreadCtx
                { _threadId = tid
                , _handlers =
                      [ ( Handler threadKilledNotifier
                        , Handler $ \(ContException e) -> throwM e)
                      ]
                }
        wrapCore $ Core $ events %= PQ.insert Event {..}
        wait $ for 1 mcs  -- real `forkIO` seems to yield execution
                          -- to newly created thread
        return tid
    wait relativeToNow = do
        cur <- localTime
        ctx <- TimedT ask
        let event following =
                Event
                { _threadCtx = ctx
                , _timestamp = cur + relativeToNow cur
                , _action = wrapCore following
                }
        -- grab our continuation, put it to event queue
        -- and finish execution
        TimedT $ lift $ ContT $ \c -> Core $ events %= PQ.insert (event $ c ())
    myThreadId = TimedT $ view threadId
    throwTo tid e = wrapCore $ Core $
        asyncExceptions %= M.alter (<|> Just (SomeException e)) tid
    -- TODO: we should probably implement this similar to
    -- http://haddock.stackage.org/lts-5.8/base-4.8.2.0/src/System-Timeout.html#timeout
    timeout t action' = do
        ref <- liftIO $ newIORef Nothing
        -- fork worker
        wtid <-
            fork $
            do res <- action'
               liftIO $ writeIORef ref $ Just res
        -- wait and gather results
        waitForRes ref wtid t
      where
        waitForRes ref tid tout = do
            lt <- localTime
            waitForRes' ref tid $ lt + tout
        waitForRes' ref tid end = do
            tNow <- localTime
            if tNow >= end
                then do
                    killThread tid
                    res <- liftIO $ readIORef ref
                    case res of
                        Nothing -> throwM $ MTTimeoutError "Timeout exceeded"
                        Just r  -> return r
                else do
                    wait $ for delay
                    res <- liftIO $ readIORef ref
                    case res of
                        Nothing -> waitForRes' ref tid end
                        Just r  -> return r
        delay = 10 :: Millisecond
