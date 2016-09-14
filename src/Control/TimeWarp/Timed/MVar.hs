{-# LANGUAGE TypeFamilies #-}

module Control.TimeWarp.Timed.MVar
    ( MonadMVar (..)
    ) where

class MonadMVar m where
    type MVar m :: * -> *

    newEmptyMVar :: m (MVar m a)

    newMVar :: a -> m (MVar m a)

    takeMVar :: MVar m a -> m a

    putMVar :: MVar m a -> a -> m ()
