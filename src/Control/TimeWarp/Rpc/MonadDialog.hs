{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TypeFamilies              #-}

-- |
-- Module      : Control.TimeWarp.Rpc.MonadDialog
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module allows to send/receive whole messages.

module Control.TimeWarp.Rpc.MonadDialog
       ( Port
       , Host
       , NetworkAddress
       , localhost

       , Message (..)
       , MonadDialog (..)

       , send
       , listen
       , reply
       , Listener (..)
       , getMethodName
       , ResponseT (..)
       , mapResponseT

       , RpcError (..)
       ) where

import           Control.Monad                      (when)
import           Control.Monad.Catch                (MonadThrow, MonadCatch, MonadMask)
import           Control.Monad.Reader               (MonadReader, ReaderT)
import           Control.Monad.State                (MonadState)
import           Control.Monad.Trans                (MonadIO, lift)
import           Data.Binary                        (Binary, Get, Put, put, get)
import           Data.Proxy                         (Proxy (..))

import           Control.TimeWarp.Logging           (WithNamedLogger, LoggerNameBox (..))
import           Control.TimeWarp.Timed             (MonadTimed, ThreadId)
import           Control.TimeWarp.Rpc.MonadTransfer (MonadTransfer (..), ResponseT (..),
                                                     Host, Port, MonadResponse (replyRaw),
                                                     NetworkAddress, mapResponseT,
                                                     RpcError (..), localhost,
                                                     sendRaw)


-- * MonadRpc

-- | Defines communication based on messages.
-- It allows to specify service data (/header/) for use by overlying protocols.
class MonadTransfer m => MonadDialog m where
    -- | Way of packing data into raw bytes.
    packMsg :: Message r
            => Put    -- ^ Packed header
            -> r      -- ^ Message
            -> m Put  -- ^ Packed (header + message)

    -- | Way of unpacking raw bytes to data.
    unpackMsg :: Message r
              => Get header           -- ^ Header parser
              -> m (Get (header, r))  -- ^ (header + message) parser


-- | Sends a message at specified address.
-- This method blocks until message fully delivered.
send :: (MonadDialog m, Message r) => NetworkAddress -> r -> m ()
send addr msg = sendRaw addr =<< packMsg mname msg
  where
    mname = put $ methodName $ proxyOf msg

-- | Starts server.
listen :: MonadDialog m => Port -> [Listener m] -> m ()
listen port _ = listenRaw port undefined undefined


-- * Listeners

-- | Creates RPC-method.
data Listener m =
    forall r . Message r => Listener (r -> ResponseT m ())

getMethodName :: Listener m -> String
getMethodName (Listener f) = methodName $ proxyOfArg f
  where
    proxyOfArg :: (a -> b) -> Proxy a
    proxyOfArg _ = Proxy

proxyOf :: a -> Proxy a
proxyOf _ = Proxy

class Binary m => Message m where
    methodName :: Proxy m -> String

instance Message () where
    methodName _ = "()"

reply :: (MonadResponse m, MonadDialog m, Message r) => r -> m ()
reply msg = replyRaw =<< packMsg (pure ()) msg

-- * Default instance

-- Uses simple packing: magic + header + packed message
newtype BinaryDialog m a = BinaryDialog (m a)
    deriving (Functor, Applicative, Monad, MonadIO,
              MonadThrow, MonadCatch, MonadMask,
              MonadReader r, MonadState s,
              WithNamedLogger, MonadTimed, MonadTransfer)

type instance ThreadId (BinaryDialog m) = ThreadId m

instance MonadTransfer m => MonadDialog (BinaryDialog m) where
    packMsg header msg = return $ do
        put binaryDialogMagic
        header
        put msg

    unpackMsg header = return $ do
        magic <- get
        when (magic /= binaryDialogMagic) $
            fail "No magic number at the beginning"
        (,) <$> header <*> get

binaryDialogMagic :: Int
binaryDialogMagic = 43532423


-- * Instances

instance MonadDialog m => MonadDialog (ReaderT r m) where
    packMsg header msg = lift $ packMsg header msg

    unpackMsg = lift . unpackMsg

deriving instance MonadDialog m => MonadDialog (LoggerNameBox m)

deriving instance MonadDialog m => MonadDialog (ResponseT m)
