{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}

module Control.TimeWarp.Timed.MVar
    ( MonadMVar (..)
    ) where

import qualified Control.Concurrent.MVar as C
import           Control.Monad.Trans        (MonadTrans (..))

class Monad m => MonadMVar m where
    type MVar m :: * -> *

    newEmptyMVar :: m (MVar m a)

    newMVar :: a -> m (MVar m a)

    takeMVar :: MVar m a -> m a

    putMVar :: MVar m a -> a -> m ()

instance MonadMVar IO where
    type MVar IO = C.MVar

    newEmptyMVar = C.newEmptyMVar

    newMVar = C.newMVar

    takeMVar = C.takeMVar

    putMVar = C.putMVar

{-
instance {-# OVERLAPPABLE #-} (MonadTrans t, MonadMVar m, Monad (t m)) => 
          MonadMVar (t m) where
    type MVar (t m) = MVar m

    newEmptyMVar = lift $ newEmptyMVar

    newMVar = lift . newMVar

    takeMVar = lift . takeMVar

    putMVar m = lift . putMVar m
-}
