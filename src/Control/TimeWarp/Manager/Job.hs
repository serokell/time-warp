{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE ViewPatterns          #-}

-- | This module provides abstractions for parallel job processing.

module Control.TimeWarp.Manager.Job
       ( -- * Job data types
         InterruptType (..)
       , JobManager    (..)
       , JobsState

         -- * 'JobsState' lenses
       , jmCounter
       , jmIsClosed
       , jmJobs

         -- * Manager utilities
       , addManagerAsJob
       , addSafeThreadJob
       , addThreadJob
       , interruptAllJobs
       , isInterrupted
       , mkJobManager
       , stopAllJobs
       , unlessInterrupted
       ) where

import           Control.Concurrent          (forkIO)
import           Control.Concurrent.STM      (atomically, check)
import           Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVar, readTVarIO,
                                              writeTVar)
import           Control.Lens                (at, makeLenses, use, view, (&), (.=), (.~),
                                              (<<+=), (<<.=), (?=), (^.))
import           Control.Monad               (mapM_, unless, void)
import           Control.Monad.Catch         (MonadMask (mask), finally)
import           Control.Monad.Extra         ((&&^))
import           Control.Monad.Trans         (MonadIO (liftIO))
import           Control.Monad.Trans.Control (MonadBaseControl (..))

import           Data.Hashable               (Hashable)
import           Data.HashMap.Strict         (HashMap)
import qualified Data.HashMap.Strict         as HM hiding (HashMap)
import           Serokell.Util.Base          (inCurrentContext)
import           Serokell.Util.Concurrent    (modifyTVarS, threadDelay)
import           System.Wlog                 (CanLog)

import           Control.TimeWarp.Timed      (Microsecond, MonadTimed, fork_, killThread,
                                              myThreadId)

-- | Unique identifier of job.
newtype JobId = JobId Word
    deriving (Show, Eq, Num, Hashable)

-- | Job killer.
newtype JobInterrupter = JobInterrupter
    { runJobInterrupter :: IO ()
    }

-- | Action to mark job as finished
newtype MarkJobFinished = MarkJobFinished
    { runMarker :: IO ()
    }

data JobsState = JobsState
    { -- | @True@ if close had been invoked
      _jmIsClosed :: !Bool

      -- | 'Map' with currently active jobs
    , _jmJobs     :: !(HashMap JobId JobInterrupter)

      -- | Total number of allocated jobs ever
    , _jmCounter  :: !JobId
    }

makeLenses ''JobsState

-- | Keeps set of jobs. Allows to stop jobs and wait till all of them finish.
newtype JobManager = JobManager
    { getJobManager :: TVar JobsState
    }

data InterruptType
    = Plain
    | Force
    | WithTimeout !Microsecond !(IO ())

mkJobManager :: MonadIO m => m JobManager
mkJobManager = JobManager <$> (liftIO $ newTVarIO
    JobsState
    { _jmIsClosed = False
    , _jmJobs     = mempty
    , _jmCounter  = 0
    })


-- | Remembers and starts given action.
-- Once `interruptAllJobs` called on this manager, if job is not completed yet,
-- `JobInterrupter` is invoked.
--
-- Given job *must* invoke given `MarkJobFinished` upon finishing, even if it was
-- interrupted.
--
-- If manager is already stopped, action would not start, and `JobInterrupter` would be
-- invoked.
addJob :: MonadIO m
       => JobManager
       -> JobInterrupter
       -> (MarkJobFinished -> m ())
       -> m ()
addJob
       (getJobManager     -> manager)
    ji@(runJobInterrupter -> interrupter)
    action
  = do
    jidm <- liftIO . atomically $ do
        st <- readTVar manager
        let closed = st ^. jmIsClosed
        if closed
            then return Nothing
            else modifyTVarS manager $ do
                    no <- jmCounter <<+= 1
                    jmJobs . at no ?= ji
                    return $ Just no
    maybe (liftIO interrupter) (action . markReady) jidm
  where
    markReady jid = MarkJobFinished $ atomically $ do
        st <- readTVar manager
        writeTVar manager $ st & jmJobs . at jid .~ Nothing

-- | Invokes `JobInterrupter`s for all incompleted jobs.
-- Has no effect on second call.
interruptAllJobs :: MonadIO m => JobManager -> InterruptType -> m ()
interruptAllJobs (getJobManager -> manager) Plain = do
    jobs <- liftIO . atomically $ modifyTVarS manager $ do
        wasClosed <- jmIsClosed <<.= True
        if wasClosed
            then return mempty
            else use jmJobs
    liftIO $ mapM_ runJobInterrupter jobs
interruptAllJobs m@(getJobManager -> manager) Force = do
    interruptAllJobs m Plain
    liftIO . atomically $ modifyTVarS manager $ jmJobs .= mempty
interruptAllJobs m@(getJobManager -> manager) (WithTimeout delay onTimeout) = do
    interruptAllJobs m Plain
    void $ liftIO . forkIO $ do
        threadDelay delay
        done <- HM.null . view jmJobs <$> readTVarIO manager
        unless done $ liftIO onTimeout >> interruptAllJobs m Force

-- | Waits for this manager to get closed and all registered jobs to invoke
-- `MaskForJobFinished`.
awaitAllJobs :: MonadIO m => JobManager -> m ()
awaitAllJobs (getJobManager -> jm) =
    liftIO . atomically $
        check =<< (view jmIsClosed &&^ (HM.null . view jmJobs)) <$> readTVar jm

-- | Interrupts and then awaits for all jobs to complete.
stopAllJobs :: MonadIO m => JobManager -> m ()
stopAllJobs m = interruptAllJobs m Plain >> awaitAllJobs m

-- | Add second manager as a job to first manager.
addManagerAsJob :: (MonadIO m, MonadTimed m, MonadBaseControl IO m)
                => JobManager -> InterruptType -> JobManager -> m ()
addManagerAsJob manager intType managerJob = do
    interrupter <- inCurrentContext $ interruptAllJobs managerJob intType
    addJob manager (JobInterrupter interrupter) $
        \(runMarker -> ready) -> fork_ $ awaitAllJobs managerJob >> liftIO ready

-- | Adds job executing in another thread, where interrupting kills the thread.
addThreadJob :: (CanLog m, MonadIO m,  MonadMask m, MonadTimed m, MonadBaseControl IO m)
             => JobManager -> m () -> m ()
addThreadJob manager action =
    mask $
        \unmask -> fork_ $ do
            tid <- myThreadId
            killer <- inCurrentContext $ killThread tid
            addJob manager (JobInterrupter killer) $
                \(runMarker -> markReady) -> unmask action `finally` liftIO markReady

-- | Adds job executing in another thread, interrupting does nothing.
-- Usefull then work stops itself on interrupt, and we just need to wait till it fully
-- stops.
addSafeThreadJob :: (MonadIO m,  MonadMask m, MonadTimed m) => JobManager -> m () -> m ()
addSafeThreadJob manager action =
    mask $
        \unmask -> fork_ $ addJob manager (JobInterrupter $ return ()) $
            \(runMarker -> markReady) -> unmask action `finally` liftIO markReady

isInterrupted :: MonadIO m => JobManager -> m Bool
isInterrupted = liftIO . atomically . fmap (view jmIsClosed) . readTVar . getJobManager

unlessInterrupted :: MonadIO m => JobManager -> m () -> m ()
unlessInterrupted m a = isInterrupted m >>= flip unless a
