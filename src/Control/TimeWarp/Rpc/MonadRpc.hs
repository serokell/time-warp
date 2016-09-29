{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE FunctionalDependencies    #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TypeFamilies              #-}

-- |
-- Module      : Control.TimeWarp.Rpc
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module contains `MonadRpc` typeclass which abstracts over
-- RPC communication.

module Control.TimeWarp.Rpc.MonadRpc
       ( Port
       , Host
       , NetworkAddress

       , TransmitionPair (methodName)
       , MonadRpc (..)
       , sendTimeout
       , Method (..)
       , getMethodName
       , proxyOf

       , scenario
       ) where

import           Control.Monad.Catch        (MonadThrow)
import           Control.Monad.Reader       (ReaderT (..))
import           Control.Monad.Trans        (lift, MonadIO (..))
import           Data.ByteString            (ByteString)
import           Data.Proxy                 (Proxy (..), asProxyTypeOf)

import           Data.MessagePack.Object    (MessagePack(..))
import           Data.Time.Units            (TimeUnit)

import           Control.TimeWarp.Logging   (LoggerNameBox (..))
import           Control.TimeWarp.Timed     (MonadTimed (timeout), sec, work, for)

-- | Port number.
type Port = Int

-- | Host address.
type Host = ByteString

-- | Full node address.
type NetworkAddress = (Host, Port)

-- | Defines name and response type of RPC-method to which data of @req@ type
-- can be delivered.
--
-- TODO: create instances of this class by TH.
class (MessagePack req, MessagePack resp) =>
       TransmitionPair req resp | req -> resp where
    methodName :: Proxy req -> String


-- | Creates RPC-method.
data Method m =
    forall req resp . TransmitionPair req resp => Method (req -> m resp)

-- | Defines protocol of RPC layer.
class MonadThrow m => MonadRpc m where
    -- | Executes remote method call.
    send :: TransmitionPair req resp =>
            NetworkAddress -> req -> m resp

    -- | Starts RPC server with a set of RPC methods.
    serve :: Port -> [Method m] -> m ()

-- | Same as `execClient`, but allows to set up timeout for a call (see
-- `Control.TimeWarp.Timed.MonadTimed.timeout`).
sendTimeout
    :: (MonadTimed m, MonadRpc m, TransmitionPair req resp, TimeUnit t)
    => t -> NetworkAddress -> req -> m resp
sendTimeout t addr = timeout t . send addr

getMethodName :: Method m -> String
getMethodName (Method f) = let rp = requestProxy
                               -- make rp contain type of f's argument
                               _ = f $ undefined `asProxyTypeOf` rp
                           in  methodName rp
  where
    requestProxy :: TransmitionPair req resp => Proxy req
    requestProxy = Proxy

-- | TODO: move to non re-exported module
proxyOf :: a -> Proxy a
proxyOf _ = Proxy

-- * Instances

instance MonadRpc m => MonadRpc (ReaderT r m) where
    send addr req = lift $ send addr req

    serve port methods = ReaderT $
                            \r -> serve port (convert r <$> methods)
      where
        convert :: Monad m => r -> Method (ReaderT r m) -> Method m
        convert r (Method f) = Method $ flip runReaderT r . f

deriving instance MonadRpc m => MonadRpc (LoggerNameBox m)

-- * Example (temporal)

data EpicRequest = EpicRequest
    { num :: Int
    , msg :: String
    }

instance MessagePack EpicRequest where
    toObject (EpicRequest a1 a2) = toObject (a1, a2)
    fromObject o = do (a1, a2) <- fromObject o
                      return $ EpicRequest a1 a2

instance TransmitionPair EpicRequest [Char] where
    methodName = const "EpicRequest"

scenario :: (MonadTimed m, MonadRpc m, MonadIO m) => m ()
scenario = do
    work (for 5 sec) $
        serve 1234 [method]
    
    res <- send ("127.0.0.1", 1234) $
        EpicRequest 14 " men on the dead man's chest"
    liftIO $ print res
  where
    method = Method $ \EpicRequest{..} -> do
        liftIO $ putStrLn "Got request, answering"
        return $ show (num + 1) ++ msg
