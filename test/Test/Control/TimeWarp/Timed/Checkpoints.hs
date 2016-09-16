module Test.Control.TimeWarp.Timed.Checkpoints
    ( withCheckPoints
    ) where

import           Control.Concurrent.STM       (atomically)
import           Control.Concurrent.STM.TVar  (TVar, modifyTVar, newTVarIO,
                                               readTVarIO)
import           Control.Monad.Trans          (MonadIO, liftIO)
import           Test.QuickCheck.Property     (Result (reason), failed,
                                               ioProperty, succeeded)


-- Principle of checkpoints: every checkpoint has it's id
-- Checkpoints should be visited in according order: 1, 2, 3 ...
newtype CheckPoints = CP { getCP :: TVar (Either String Int) }

initCheckPoints :: MonadIO m => m CheckPoints
initCheckPoints = fmap CP $ liftIO $ newTVarIO $ Right 0

visitCheckPoint :: MonadIO m => CheckPoints -> Int -> m ()
visitCheckPoint cp curId = liftIO $ atomically $ modifyTVar (getCP cp) $
    \wasId ->
        if wasId == Right (curId - 1)
            then Right curId
            else Left $ either id (showError curId) wasId
  where
    showError cur was = mconcat
        ["Wrong chechpoint. Expected "
        , show (was + 1)
        , ", but visited "
        , show cur
        ]

assertCheckPoints :: MonadIO m => CheckPoints -> m Result
assertCheckPoints = fmap mkRes . liftIO . readTVarIO . getCP
  where
    mkRes (Left msg) = failed { reason = msg }
    mkRes (Right _)  = succeeded

withCheckPoints :: MonadIO m => ((Int -> m ()) -> IO a) -> IO Result
withCheckPoints act = do
    cp <- initCheckPoints
    _  <- act $ liftIO . visitCheckPoint cp
    assertCheckPoints cp
