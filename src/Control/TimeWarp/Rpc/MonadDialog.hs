{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE DefaultSignatures         #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE FunctionalDependencies    #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TupleSections             #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE UndecidableInstances      #-}

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

       , sendP
       , listenP
       , replyP

       , MonadDialog (..)
       , send
       , listen
       , reply

       , Listener (..)
       , getListenerName

       , ResponseT (..)
       , mapResponseT

       , Dialog (..)
       , runDialog

       , RpcError (..)
       ) where

import           Control.Lens                       (at, (^.))
import           Control.Monad                      (forM_)
import           Control.Monad.Catch                (MonadCatch, MonadMask, MonadThrow)
import           Control.Monad.Reader               (MonadReader (ask), ReaderT (..))
import           Control.Monad.State                (MonadState)
import           Control.Monad.Trans                (MonadTrans (..), MonadIO)
import           Data.ByteString                    (ByteString)
import           Data.Conduit                       (Consumer, yield, ($=))
import           Data.Conduit.List                  as CL
import           Data.Map                           as M
import           Data.Proxy                         (Proxy (..))
import           Formatting                         (sformat, shown, (%))

import           Control.TimeWarp.Logging           (LoggerNameBox (..), WithNamedLogger)
import           Control.TimeWarp.Rpc.Message       (ContentData (..), Message (..),
                                                     NameData (..), NameNContentData (..),
                                                     Packable (..), Unpackable (..),
                                                     intangibleSink)
import           Control.TimeWarp.Rpc.MonadTransfer (Binding, Host,
                                                     MonadResponse (replyRaw),
                                                     MonadTransfer (..), NetworkAddress,
                                                     Port, ResponseT (..), RpcError (..),
                                                     localhost, mapResponseT,
                                                     hoistRespCond)
import           Control.TimeWarp.Timed             (MonadTimed, ThreadId)


-- * MonadRpc

-- | Defines communication based on messages.
-- It allows to specify service data (/header/) for use by overlying protocols.
class MonadTransfer m => MonadDialog p m | m -> p where
    packingType :: m p

-- * Communication methods

-- ** Packing type manually defined

-- | Send a message.
sendP :: (Packable p (ContentData r), MonadTransfer m)
      => p -> NetworkAddress -> r -> m ()
sendP packing addr msg = sendRaw addr $ yield (ContentData msg) $= packMsg packing

-- | Sends message to peer node.
replyP :: (Packable p (ContentData r), MonadResponse m)
       => p -> r -> m ()
replyP packing msg = replyRaw $ yield (ContentData msg) $= packMsg packing

-- | Starts server.
listenP :: (MonadTransfer m, WithNamedLogger m, MonadThrow m, MonadIO m,
            Unpackable p NameData)
       => p -> Binding -> [Listener p m] -> m ()
listenP packing port listeners =
    listenRaw port $ mergeListeners packing listeners

-- | For given listeners creates single parser-conduit and single handler with
-- same functionality.
-- Resulting parser returns @(no, dyn)@, where
--
-- 1. @no@ is number of matched listener;
--
-- 2. @dyn@ - parsed object, converted to @Dynamic@.
--
-- Handler accepts this pair and chooses /listener/ with specified number to apply.
mergeListeners :: (MonadTransfer m, WithNamedLogger m, MonadThrow m, MonadIO m,
                   Unpackable p NameData)
               => p
               -> [Listener p m]
               -> Consumer ByteString (ResponseT m) ()
mergeListeners packing listeners = loop
  where
    loop = do
        nameM <- intangibleSink $ unpackMsg packing
        forM_ nameM $
            \(NameData name) ->
                case listenersMap ^. at name of
                    Nothing -> error $ show $
                        sformat ("No listener with name "%shown%" defined") name
                    Just (Listener f) -> do
                        msgM <- unpackMsg packing $= CL.head
                        forM_ msgM $
                            \(NameNContentData _ r) -> lift (f r) >> loop

    listenersMap = M.fromList [(getListenerName li, li) | li <- listeners]

-- ** For MonadDialog

-- | Send a message.
send :: (Packable p (ContentData r), MonadDialog p m)
     => NetworkAddress -> r -> m ()
send addr msg = packingType >>= \p -> sendP p addr msg

-- | Sends message to peer node.
reply :: (Packable p (ContentData r), MonadDialog p m, MonadResponse m)
      => r -> m ()
reply msg = packingType >>= \p -> replyP p msg

-- | Starts server.
listen :: (MonadDialog p m, WithNamedLogger m, MonadThrow m, MonadIO m,
            Unpackable p NameData)
       => Binding -> [Listener p m] -> m ()
listen port listeners =
    packingType >>= \p -> listenP p port listeners


-- * Listeners

-- | Creates RPC-method.
data Listener p m =
    forall r . (Unpackable p (NameNContentData r), Message r)
             => Listener (r -> ResponseT m ())

getListenerName :: Listener p m -> ByteString
getListenerName (Listener f) = messageName $ proxyOfArg f
  where
    proxyOfArg :: (a -> b) -> Proxy a
    proxyOfArg _ = Proxy


-- * Default instance of MonadDialog

newtype Dialog p m a = Dialog
    { getDialog :: ReaderT p m a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadTrans,
                MonadThrow, MonadCatch, MonadMask,
                MonadState s,
                WithNamedLogger, MonadTimed)

runDialog :: p -> Dialog p m a -> m a
runDialog p = flip runReaderT p . getDialog

type instance ThreadId (Dialog p m) = ThreadId m

instance MonadTransfer m => MonadTransfer (Dialog p m) where
    sendRaw addr req = lift $ sendRaw addr req
    listenRaw binding sink =
        Dialog $ listenRaw binding $ hoistRespCond getDialog sink
    close = lift . close

instance MonadTransfer m => MonadDialog p (Dialog p m) where
    packingType = Dialog ask


-- * Instances

instance MonadDialog p m => MonadDialog p (ReaderT r m) where
    packingType = lift packingType

deriving instance MonadDialog p m => MonadDialog p (LoggerNameBox m)

deriving instance MonadDialog p m => MonadDialog p (ResponseT m)
