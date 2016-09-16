module Test.Control.TimeWarp.Timed.MVarSpec
    ( spec
    ) where

import           Control.Monad                (replicateM_, forM_)
import           Control.Monad.Trans          (MonadIO, liftIO)
import           Data.IORef                   (newIORef, readIORef, writeIORef)
import           Test.Hspec                   (Spec, before, describe)
import           Test.Hspec.QuickCheck        (prop)
import           Test.QuickCheck              (NonNegative (..), Property)
import           Test.QuickCheck.Property     (ioProperty)

import           Control.TimeWarp.Logging     (Severity (Error), initLogging)
import           Control.TimeWarp.Timed       (MonadTimed (..), fork_,
                                               runTimedT, for, sec)
import           Control.TimeWarp.Timed.MVar  (MonadMVar (..))
import           Test.Control.TimeWarp.Common ()
import           Test.Control.TimeWarp.Timed.Checkpoints (withCheckPoints)

spec :: Spec
spec =
    before (initLogging ["dunno"] Error) $
    describe "Pure Mvar" $ do
        describe "order" $ do
            prop "take blocks threads"
                takeBlocksThreads
            prop "several producers"
                severalProducers

takeBlocksThreads
    :: Property
takeBlocksThreads =
    ioProperty . withCheckPoints $
        \checkPoint -> runTimedT $
         do m <- newEmptyMVar
            fork_ $ forM_ [0..10] $
                \i -> do wait (for 3 sec)
                         checkPoint $ 2 * i + 1
                         putMVar m ()
            fork_ $ forM_ [0..] $
                \i -> do _ <- takeMVar m
                         checkPoint $ 2 * i + 2

severalProducers
    :: Property
severalProducers =
    ioProperty . withCheckPoints $
        \checkPoint -> runTimedT $
         do m  <- newEmptyMVar
            -- counter for producers
            cp <- counter
            -- counter for consumer
            cc <- counter
            forM_ [1..3] $
                \i -> 
                do wait (for i sec)
                   fork $ replicateM_ 10 $
                       do wait (for 3 sec)
                          no <- cp
                          checkPoint $ 2 * no - 1
                          putMVar m ()
            fork_ $ replicateM_ 999 $
                do _ <- takeMVar m
                   no <- cc
                   checkPoint $ 2 * no


counter :: MonadIO m => m (m Int)
counter = liftIO $ newIORef 1 >>=
    \ref -> return . liftIO $ do
        v <- readIORef ref
        writeIORef ref $ v + 1
        return v


