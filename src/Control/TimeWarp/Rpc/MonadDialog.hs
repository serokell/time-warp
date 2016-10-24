{-# LANGUAGE DefaultSignatures         #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE FunctionalDependencies    #-}
{-# LANGUAGE ConstraintKinds           #-}
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
       , listenPE
       , listenOutboundP
       , listenOutboundPE
       , replyP

       , MonadDialog (..)
       , send
       , listen
       , listenE
       , listenOutbound
       , listenOutboundE
       , reply

       , Listener (..)
       , getListenerName

       , ResponseT (..)
       , mapResponseT

       , Dialog (..)
       , runDialog

       , RpcError (..)
       ) where

import           Control.Lens                       ((^.), at)
import           Control.Monad                      (forever)
import           Control.Monad.Catch                (MonadThrow, MonadCatch, MonadMask)
import           Control.Monad.Reader               (MonadReader (ask), ReaderT (..))
import           Control.Monad.State                (MonadState)
import           Control.Monad.Trans                (MonadIO, lift)
import           Data.ByteString                    (ByteString)
import           Data.Conduit                       (Conduit, ($=), (=$), yield)
import           Data.Conduit.List                  as CL
import           Data.Dynamic                       (Dynamic, fromDyn, toDyn)
import           Data.Map                           as M
import           Data.Proxy                         (Proxy (..))
import qualified Data.Text                          as T
import           Formatting                         (sformat, (%), shown)

import           Control.TimeWarp.Logging           (WithNamedLogger, LoggerNameBox (..))
import           Control.TimeWarp.Timed             (MonadTimed, ThreadId)
import           Control.TimeWarp.Rpc.Message       (Message (..), Serializable (..),
                                                     NamedSerializable,
                                                     NamedPacking (..))
import           Control.TimeWarp.Rpc.MonadTransfer (MonadTransfer (..), ResponseT (..),
                                                     Host, Port, MonadResponse (replyRaw),
                                                     NetworkAddress, mapResponseT,
                                                     RpcError (..), localhost,
                                                     sendRaw)


-- * MonadRpc

-- | Defines communication based on messages.
-- It allows to specify service data (/header/) for use by overlying protocols.
class MonadTransfer m => MonadDialog p m | m -> p where
    packingType :: m p

-- * Communication methods

-- ** Packing type manually defined

-- | Send a message.
sendP :: (Serializable p r, MonadTransfer m)
      => p -> NetworkAddress -> r -> m ()
sendP packing addr msg = sendRaw addr $ yield msg $= packMsg packing

-- | Sends message to peer node.
replyP :: (Serializable p r, MonadResponse m)
       => p -> r -> m ()
replyP packing msg = replyRaw $ yield msg $= packMsg packing

-- | Starts server, allows to specify error handler.
listenPE :: (NamedPacking p, MonadTransfer m)
       => p -> Port -> ErrorHandler m -> [Listener p m] -> m ()
listenPE packing port handler listeners =
    uncurry (listenRaw port) $ mergeListeners packing listeners handler

-- | Starts server.
listenP :: (NamedPacking p, MonadTransfer m)
       => p -> Port -> [Listener p m] -> m ()
listenP packing port = listenPE packing port nopHandler

-- | Listens for incomings on outbound connection. Allows to specify error handler.
listenOutboundPE :: (NamedPacking p, MonadTransfer m)
               => p -> NetworkAddress -> ErrorHandler m -> [Listener p m] -> m ()
listenOutboundPE packing addr handler listeners =
    uncurry (listenOutboundRaw addr) $ mergeListeners packing listeners handler

-- | Listens for incomings on outbound connection.
listenOutboundP :: (NamedPacking p, MonadTransfer m)
               => p -> NetworkAddress -> [Listener p m] -> m ()
listenOutboundP packing addr =
    listenOutboundPE packing addr nopHandler


-- | For given listeners creates single parser-conduit and single handler with
-- same functionality.
-- Resulting parser returns @(no, dyn)@, where
--
-- 1. @no@ is number of matched listener;
--
-- 2. @dyn@ - parsed object, converted to @Dynamic@.
--
-- Handler accepts this pair and chooses /listener/ with specified number to apply.
mergeListeners :: (MonadTransfer m, NamedPacking p)
               => p
               -> [Listener p m]
               -> ErrorHandler m
               -> ( Conduit ByteString IO (Either T.Text (Listener p m, Dynamic))
                  , Either T.Text (Listener p m, Dynamic) -> ResponseT m ()
                  )
mergeListeners packing listeners onError = (cond, handler)
  where
    -- find listener with same messageName and pass it & decoded data
    cond = forever $ do
        nameE <- lookMsgName packing =$ CL.peek
        case nameE of
            Nothing           -> return ()  -- end of stream
            Just (Left e)     -> yield $ Left $
                sformat ("Failed to get message name: "%shown) e
            Just (Right name) ->
                case listenersMap ^. at name of
                    Nothing -> yield $ Left $
                        sformat ("No listener with name"%shown%"defined") name
                    Just li -> condLi li

    -- for given listener, decode data and pass listener & data
    condLi li@(Listener f) = do
        objE <- unpackMsg packing =$ CL.head
        case objE of
            Nothing          -> yield $ Left $
                sformat ("Unexpected end of input while parsing message content")
            Just (Left e)    -> yield $ Left $
                sformat ("Failed to get message content: "%shown) e
            Just (Right obj) ->
                let _ = f obj  -- restrict type
                in  yield $ Right (li, toDyn obj)
                
    handler (Left err)                = onError err
    handler (Right (Listener f, dyn)) = f $ fromDyn dyn typeMismatchE

    typeMismatchE = error $ "mergeListeners: type mismatch. Probably messages of"
                         ++ "different types have same messageName"

    listenersMap = M.fromList [(getListenerName li, li) | li <- listeners]


-- ** For MonadDialog

-- | Send a message.
send :: (Serializable p r, MonadDialog p m)
     => NetworkAddress -> r -> m ()
send addr msg = packingType >>= \p -> sendP p addr msg

-- | Sends message to peer node.
reply :: (Serializable p r, MonadDialog p m, MonadResponse m)
      => r -> m ()
reply msg = packingType >>= \p -> replyP p msg

-- | Starts server. Allows to specify error handler.
listenE :: (NamedPacking p, MonadDialog p m)
       => Port -> ErrorHandler m -> [Listener p m] -> m ()
listenE port handler listeners =
    packingType >>= \p -> listenPE p port handler listeners

-- | Starts server.
listen :: (NamedPacking p, MonadDialog p m)
       => Port -> [Listener p m] -> m ()
listen port = listenE port nopHandler


-- | Listens for incomings on outbound connection. Allows to specify error handler.
listenOutboundE :: (NamedPacking p, MonadDialog p m)
               => NetworkAddress -> ErrorHandler m -> [Listener p m] -> m ()
listenOutboundE addr handler listeners =
    packingType >>= \p -> listenOutboundPE p addr handler listeners

-- | Listens for incomings on outbound connection.
listenOutbound :: (NamedPacking p, MonadDialog p m)
               => NetworkAddress -> [Listener p m] -> m ()
listenOutbound addr = listenOutboundE addr nopHandler


nopHandler :: Monad m => T.Text -> m ()
nopHandler _ = return ()

-- * Listeners

-- | Creates RPC-method.
data Listener p m =
    forall r . NamedSerializable p r => Listener (r -> ResponseT m ())

getListenerName :: Listener p m -> ByteString
getListenerName (Listener f) = messageName $ proxyOfArg f
  where
    proxyOfArg :: (a -> b) -> Proxy a
    proxyOfArg _ = Proxy


type ErrorHandler m = T.Text -> ResponseT m ()

-- * Default instance of MonadDialog

newtype Dialog p m a = Dialog
    { getDialog :: ReaderT p m a
    } deriving (Functor, Applicative, Monad, MonadIO,
                MonadThrow, MonadCatch, MonadMask,
                MonadState s,
                WithNamedLogger, MonadTimed, MonadTransfer)

runDialog :: p -> Dialog p m a -> m a
runDialog p = flip runReaderT p . getDialog

type instance ThreadId (Dialog p m) = ThreadId m

instance MonadTransfer m => MonadDialog p (Dialog p m) where
    packingType = Dialog ask


-- * Instances

instance MonadDialog p m => MonadDialog p (ReaderT r m) where
    packingType = lift packingType

deriving instance MonadDialog p m => MonadDialog p (LoggerNameBox m)

deriving instance MonadDialog p m => MonadDialog p (ResponseT m)
