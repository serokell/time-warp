{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE RankNTypes             #-}
{-# LANGUAGE StandaloneDeriving     #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE UndecidableInstances   #-}

module Control.TimeWarp.Node
    ( NodeProcess (..)
    , NodeField (..)
    , NodeId
    , runNodeField
    , InsideNode (..)
    , WithNodes (..)
    ) where

import           Control.Concurrent.STM      (atomically)
import           Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVar, writeTVar)
import           Control.Monad.Base          (MonadBase)
import           Control.Monad.Catch         (MonadThrow, MonadCatch, MonadMask)
import           Control.Monad.Reader        (ReaderT, runReaderT, MonadReader (..),
                                              mapReaderT)
import           Control.Monad.State         (MonadState)
import           Control.Monad.Trans         (MonadTrans (..), MonadIO (..))
import           Control.Monad.Trans.Control (MonadBaseControl (..))

import           Control.TimeWarp.Logging    (WithNamedLogger)

newtype NodeId = NodeId Int
    deriving (Eq, Ord)

newtype NodeProcess m a = NodeProcess 
    { getNodeProcess :: ReaderT NodeId m a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadTrans,
                MonadThrow, MonadCatch, MonadMask,
                MonadState s,
                WithNamedLogger)

deriving instance MonadBase IO m => MonadBase IO (NodeProcess m)

instance MonadBaseControl IO m => MonadBaseControl IO (NodeProcess m) where
    type StM (NodeProcess m) a = StM (ReaderT NodeId m) a
    liftBaseWith io =
        NodeProcess $ liftBaseWith $ \runInBase -> io $ runInBase . getNodeProcess
    restoreM = NodeProcess . restoreM

instance MonadReader r m => MonadReader r (NodeProcess m) where
    ask = lift  ask
    reader = lift . reader
    local f (NodeProcess m) = NodeProcess $ mapReaderT (local f) m

newtype NodeField m a = NodeField
    { getNodeField :: ReaderT (TVar Int) m a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadTrans,
                MonadThrow, MonadCatch, MonadMask,
                MonadState s,
                WithNamedLogger)

deriving instance MonadBase IO m => MonadBase IO (NodeField m)

runNodeField :: MonadIO m => NodeField m a -> m a
runNodeField nf = liftIO (newTVarIO 0) >>= runReaderT (getNodeField nf)

class WithNodes n c | c -> n, n -> c where
    newNode :: n a -> c a

instance MonadIO m => WithNodes (NodeProcess m) (NodeField m) where
    newNode p = do
        counter <- NodeField ask
        nid <- liftIO . atomically $ do
            nid <- readTVar counter
            writeTVar counter (nid + 1)
            return nid
        lift $ runReaderT (getNodeProcess p) (NodeId nid)


-- * InsideNode

class Monad m => InsideNode m where
    getNodeId :: m NodeId

instance Monad m => InsideNode (NodeProcess m) where
    getNodeId = NodeProcess ask

instance InsideNode m => InsideNode (ReaderT r m) where
    getNodeId = lift getNodeId
