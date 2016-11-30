{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}

-- | This module provides abstractions for parallel job processing.

module Control.TimeWarp.Manager.Job
       ( -- * Job data types
         InterruptType (..)
       , JobManager
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
import           Control.Monad               (unless, void)
import           Control.Monad.Catch         (MonadMask (mask), finally)
import           Control.Monad.Trans         (MonadIO (liftIO))
import           Control.Monad.Trans.Control (MonadBaseControl (..))

import           Data.Map.Strict             (Map)
import qualified Data.Map.Strict             as M hiding (Map)
import           Serokell.Util.Base          (inCurrentContext)
import           Serokell.Util.Concurrent    (modifyTVarS, threadDelay)
import           System.Wlog                 (CanLog)

import           Control.TimeWarp.Timed      (Microsecond, MonadTimed, fork_, killThread,
                                              myThreadId)

type JobId = Int

type JobInterrupter = IO ()

type MarkJobFinished = IO ()

data JobsState = JobsState
    { -- | @True@ if close had been invoked
      _jmIsClosed :: Bool

      -- | 'Map' with currently active jobs
    , _jmJobs     :: Map JobId JobInterrupter

      -- | Total number of allocated jobs ever
    , _jmCounter  :: JobId
    }

makeLenses ''JobsState

-- | Keeps set of jobs. Allows to stop jobs and wait till all of them finish.
type JobManager = TVar JobsState

data InterruptType
    = Plain
    | Force
    | WithTimeout Microsecond (IO ())

mkJobManager :: MonadIO m => m JobManager
mkJobManager = liftIO . newTVarIO $
    JobsState
    { _jmIsClosed = False
    , _jmJobs     = mempty
    , _jmCounter  = 0
    }


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
       => JobManager -> JobInterrupter -> (MarkJobFinished -> m ()) -> m ()
addJob manager interrupter action = do
    jidm <- liftIO . atomically $ do
        st <- readTVar manager
        let closed = st ^. jmIsClosed
        if closed
            then return Nothing
            else modifyTVarS manager $ do
                    no <- jmCounter <<+= 1
                    jmJobs . at no ?= interrupter
                    return $ Just no
    maybe (liftIO interrupter) (action . markReady) jidm
  where
    markReady jid = atomically $ do
        st <- readTVar manager
        writeTVar manager $ st & jmJobs . at jid .~ Nothing

-- | Invokes `JobInterrupter`s for all incompleted jobs.
-- Has no effect on second call.
interruptAllJobs :: MonadIO m => JobManager -> InterruptType -> m ()
interruptAllJobs m Plain = do
    jobs <- liftIO . atomically $ modifyTVarS m $ do
        wasClosed <- jmIsClosed <<.= True
        if wasClosed
            then return M.empty
            else use jmJobs
    liftIO $ sequence_ jobs
interruptAllJobs m Force = do
    interruptAllJobs m Plain
    liftIO . atomically $ modifyTVarS m $ jmJobs .= M.empty
interruptAllJobs m (WithTimeout delay onTimeout) = do
    interruptAllJobs m Plain
    void $ liftIO . forkIO $ do
        threadDelay delay
        done <- M.null . view jmJobs <$> readTVarIO m
        unless done $ liftIO onTimeout >> interruptAllJobs m Force

-- | Waits for this manager to get closed and all registered jobs to invoke
-- `MaskForJobFinished`.
awaitAllJobs :: MonadIO m => JobManager -> m ()
awaitAllJobs m =
    liftIO . atomically $
        check =<< ((&&) <$> view jmIsClosed <*> M.null . view jmJobs) <$> readTVar m

-- | Interrupts and then awaits for all jobs to complete.
stopAllJobs :: MonadIO m => JobManager -> m ()
stopAllJobs m = interruptAllJobs m Plain >> awaitAllJobs m

-- | Add second manager as a job to first manager.
addManagerAsJob :: (MonadIO m, MonadTimed m, MonadBaseControl IO m)
                => JobManager -> InterruptType -> JobManager -> m ()
addManagerAsJob manager intType managerJob = do
    interrupter <- inCurrentContext $ interruptAllJobs managerJob intType
    addJob manager interrupter $
        \ready -> fork_ $ awaitAllJobs managerJob >> liftIO ready

-- | Adds job executing in another thread, where interrupting kills the thread.
addThreadJob :: (CanLog m, MonadIO m,  MonadMask m, MonadTimed m, MonadBaseControl IO m)
             => JobManager -> m () -> m ()
addThreadJob manager action =
    mask $
        \unmask -> fork_ $ do
            tid <- myThreadId
            killer <- inCurrentContext $ killThread tid
            addJob manager killer $
                \markReady -> unmask action `finally` liftIO markReady

-- | Adds job executing in another thread, interrupting does nothing.
-- Usefull then work stops itself on interrupt, and we just need to wait till it fully
-- stops.
addSafeThreadJob :: (MonadIO m,  MonadMask m, MonadTimed m) => JobManager -> m () -> m ()
addSafeThreadJob manager action =
    mask $
        \unmask -> fork_ $ addJob manager (return ()) $
            \markReady -> unmask action `finally` liftIO markReady

isInterrupted :: MonadIO m => JobManager -> m Bool
isInterrupted = liftIO . atomically . fmap (view jmIsClosed) . readTVar

unlessInterrupted :: MonadIO m => JobManager -> m () -> m ()
unlessInterrupted m a = isInterrupted m >>= flip unless a
