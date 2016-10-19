{-# LANGUAGE DefaultSignatures         #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TupleSections             #-}
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

       , MonadDialog (..)

       , send
       , sendH
       , listen
       , listenH
       , listenOutbound
       , listenOutboundH
       , reply
       , replyH
       , Listener (..)
       , ListenerH (..)
       , getMethodName
       , getMethodNameH

       , ResponseT (..)
       , mapResponseT

       , BinaryDialog (..)

       , RpcError (..)
       ) where

import           Control.Lens                       ((<&>))
import           Control.Monad                      (when)
import           Control.Monad.Catch                (MonadThrow, MonadCatch, MonadMask)
import           Control.Monad.Reader               (MonadReader, ReaderT)
import           Control.Monad.State                (MonadState)
import           Control.Monad.Trans                (MonadIO, lift)
import           Data.Binary                        (Get, Put, put, get)
import           Data.Dynamic                       (Typeable, Dynamic, toDyn, fromDyn)
import           Data.Foldable                      (foldMap)
import           Data.Monoid                        (Alt (..))
import           Data.Proxy                         (Proxy (..))
import qualified Data.Traversable                   as T

import           Control.TimeWarp.Logging           (WithNamedLogger, LoggerNameBox (..))
import           Control.TimeWarp.Timed             (MonadTimed, ThreadId)
import           Control.TimeWarp.Rpc.Message       (Message (..))
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
            -> m Put  -- ^ Packed (header + message name + message content)

    -- | Way of unpacking raw bytes to data. Should fail, if /message name/ doesn't
    -- match
    unpackMsg :: Message r
              => Get header           -- ^ Header parser
              -> m (Get (header, r))  -- ^ (header + message) parser


-- * Communication methods
-- Methods, which name end with *H* accept /header/ and aren't type-safe; use them
-- to implement overlying protocol.

-- | Send a message.
sendH :: (MonadDialog m, Message r) => NetworkAddress -> Put -> r -> m ()
sendH addr header msg = sendRaw addr =<< packMsg header msg

send :: (MonadDialog m, Message r) => NetworkAddress -> r -> m ()
send addr msg = sendH addr (pure ()) msg

-- | Sends message to peer node.
replyH :: (MonadResponse m, MonadDialog m, Message r) => Put -> r -> m ()
replyH header msg = replyRaw =<< packMsg header msg

reply :: (MonadResponse m, MonadDialog m, Message r) => r -> m ()
reply msg = replyH (pure ()) msg

-- | Starts server.
listenH :: MonadDialog m => Port -> Get h -> [ListenerH h m] -> m ()
listenH port headParser listeners =
    mergeListeners headParser listeners >>= uncurry (listenRaw port)

listen :: MonadDialog m => Port -> [Listener m] -> m ()
listen port listeners = listenH port (pure ()) $ convert <$> listeners
  where
    convert (Listener f) = ListenerH $ f . snd

-- | Listens for incomings on outbound connection.
listenOutboundH :: MonadDialog m => NetworkAddress -> Get h -> [ListenerH h m] -> m ()
listenOutboundH addr headParser listeners =
    mergeListeners headParser listeners >>= uncurry (listenOutboundRaw addr)

listenOutbound :: MonadDialog m => NetworkAddress -> [Listener m] -> m ()
listenOutbound addr listeners = listenOutboundH addr (pure ()) $ convert <$> listeners
  where
    convert (Listener f) = ListenerH $ f . snd

-- | For given header parser and listeners creates single parser and single handler with
-- same functionality.
-- Resulting parser returns @(no, dyn)@, where
--
-- 1. @no@ is number of first listener, for which succesfully parsed object of required
-- request-type;
--
-- 2. @dyn@ - parsed object, converted to @Dynamic@.
--
-- Handler accepts this pair and chooses /listener/ with specified number to apply.
mergeListeners :: MonadDialog m
               => Get h
               -> [ListenerH h m]
               -> m (Get (Int, Dynamic), (Int, Dynamic) -> ResponseT m ())
mergeListeners headParser listeners = (, handler) <$> mergedParser
  where
    mergedParser :: MonadDialog m => m (Get (Int, Dynamic))
    mergedParser = dynParsers <&> getAlt . foldMap Alt . map sequence . zip [0..]

    dynParsers :: MonadDialog m => m [Get Dynamic]
    dynParsers = T.for listeners $
        \case ListenerH f -> unpackMsg headParser <&>
                \parser -> let _ = f <$> parser
                           in  toDyn <$> parser

    handler (no, dyn) =
        case listeners !! no of
            ListenerH f -> f $ fromDyn dyn typeMismatchE

    typeMismatchE = error $ "mergeListeners: type mismatch. Probably messages of"
                         ++ "different types can be `unpackMsg`ed successfully"


-- * Listeners

-- | Creates RPC-method.
data Listener m =
    forall r . Message r => Listener (r -> ResponseT m ())

data ListenerH h m =
    forall r . (Typeable h, Message r) => ListenerH ((h, r) -> ResponseT m ())

getMethodNameH :: ListenerH h m -> String
getMethodNameH (ListenerH f) = messageName $ proxyOfArg f
  where
    proxyOfArg :: ((a, b) -> c) -> Proxy b
    proxyOfArg _ = Proxy

getMethodName :: Listener m -> String
getMethodName (Listener f) = messageName $ proxyOfArg f
  where
    proxyOfArg :: (a -> b) -> Proxy a
    proxyOfArg _ = Proxy

proxyOf :: a -> Proxy a
proxyOf _ = Proxy


-- * Default instance

-- Uses simple packing: magic + header + packed message
newtype BinaryDialog m a = BinaryDialog
    { runBinaryDialog :: m a
    } deriving (Functor, Applicative, Monad, MonadIO,
                MonadThrow, MonadCatch, MonadMask,
                MonadReader r, MonadState s,
                WithNamedLogger, MonadTimed, MonadTransfer)

type instance ThreadId (BinaryDialog m) = ThreadId m

instance MonadTransfer m => MonadDialog (BinaryDialog m) where
    packMsg header msg = return $ do
        put binaryDialogMagic
        -- TODO: put some hash of (messageName msg) would be nice here
        put $ messageName $ proxyOf msg
        header
        put msg

    unpackMsg header = return . withResultType $
        \resProxy -> do
            magic <- get
            when (magic /= binaryDialogMagic) $
                fail "No magic number at the beginning"
            mname <- get
            when (mname /= messageName resProxy) $
                fail "Message name doesn't match"
            (,) <$> header <*> get
      where
        withResultType :: (Proxy r -> Get (h, r)) -> Get (h, r)
        withResultType = ($ Proxy)

binaryDialogMagic :: Int
binaryDialogMagic = 43532423


-- * Instances

instance MonadDialog m => MonadDialog (ReaderT r m) where
    packMsg header msg = lift $ packMsg header msg

    unpackMsg = lift . unpackMsg

deriving instance MonadDialog m => MonadDialog (LoggerNameBox m)

deriving instance MonadDialog m => MonadDialog (ResponseT m)
