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
       , sendHP
       , sendRP
       , listenP
       , listenHP
       , listenRP
       , replyP
       , replyHP
       , replyRP

       , MonadDialog (..)
       , send
       , sendH
       , sendR
       , listen
       , listenH
       , listenR
       , reply
       , replyH
       , replyR


       , Listener (..)
       , ListenerH (..)
       , getListenerName
       , getListenerNameH

       , Dialog (..)
       , runDialog

       , RpcError (..)
       ) where

import           Control.Lens                       (at, (^.))
import           Control.Monad                      (forM, forM_)
import           Control.Monad.Catch                (MonadCatch, MonadMask, MonadThrow,
                                                     handleAll)
import           Control.Monad.Reader               (MonadReader (ask), ReaderT (..))
import           Control.Monad.State                (MonadState)
import           Control.Monad.Trans                (MonadIO, MonadTrans (..))
import           Data.ByteString                    (ByteString)
import           Data.Conduit                       (Consumer, yield, (=$=))
import           Data.Conduit.List                  as CL
import           Data.Map                           as M
import           Data.Proxy                         (Proxy (..))
import           Formatting                         (sformat, (%), stext, shown)

import           Control.TimeWarp.Logging           (LoggerNameBox (..), WithNamedLogger,
                                                     logWarning, logDebug, logError)
import           Control.TimeWarp.Rpc.Message       (Empty (..), HeaderNContentData (..),
                                                     HeaderNNameData (..),
                                                     HeaderNRawData (..), Message (..),
                                                     MessageName, Packable (..),
                                                     RawData (..), Unpackable (..),
                                                     intangibleSink)
import           Control.TimeWarp.Rpc.MonadTransfer (Binding, Host,
                                                     MonadResponse (replyRaw, peerAddr),
                                                     MonadTransfer (..), NetworkAddress,
                                                     Port, ResponseT (..), RpcError (..),
                                                     hoistRespCond, localhost, commLog)
import           Control.TimeWarp.Timed             (MonadTimed, ThreadId)


-- * MonadRpc

-- | Defines communication based on messages.
-- It allows to specify service data (/header/) for use by overlying protocols.
class MonadTransfer m => MonadDialog p m | m -> p where
    packingType :: m p

-- * Communication methods
-- ** For MonadDialog

-- NOTE: those `Packable` and `Unpackable` constraints were expected to play nicely with
-- different kinds of `send`, `reply` and `listen` functions, but they weren't :(

-- | Send a message.
send :: (Packable p (HeaderNContentData Empty r), MonadDialog p m)
     => NetworkAddress -> r -> m ()
send addr msg = packingType >>= \p -> sendP p addr msg

sendH :: (Packable p (HeaderNContentData h r), MonadDialog p m)
      => NetworkAddress -> h -> r -> m ()
sendH addr h msg = packingType >>= \p -> sendHP p addr h msg

sendR :: (Packable p (HeaderNRawData h), MonadDialog p m)
      => NetworkAddress -> h -> RawData -> m ()
sendR addr h raw = packingType >>= \p -> sendRP p addr h raw

-- | Sends message to peer node.
reply :: (Packable p (HeaderNContentData Empty r), MonadDialog p m, MonadResponse m)
      => r -> m ()
reply msg = packingType >>= \p -> replyP p msg

replyH :: (Packable p (HeaderNContentData h r), MonadDialog p m, MonadResponse m)
       => h -> r -> m ()
replyH h msg = packingType >>= \p -> replyHP p h msg

replyR :: (Packable p (HeaderNRawData h), MonadDialog p m, MonadResponse m)
       => h -> RawData -> m ()
replyR h raw = packingType >>= \p -> replyRP p h raw

-- | Starts server.
listen :: (Unpackable p (HeaderNNameData Empty), Unpackable p (HeaderNRawData Empty),
           MonadListener m, MonadDialog p m)
       => Binding -> [Listener p m] -> m ()
listen binding listeners =
    packingType >>= \p -> listenP p binding listeners

listenH :: (Unpackable p (HeaderNNameData h), Unpackable p (HeaderNRawData h),
            MonadListener m, MonadDialog p m)
        => Binding -> [ListenerH p h m] -> m ()
listenH binding listeners =
    packingType >>= \p -> listenHP p binding listeners

listenR :: (Unpackable p (HeaderNNameData h), Unpackable p (HeaderNRawData h),
            MonadListener m, MonadDialog p m)
        => Binding -> [ListenerH p h m] -> ListenerR h m -> m ()
listenR binding listeners rawListener =
    packingType >>= \p -> listenRP p binding listeners rawListener


-- ** Packing type manually defined

-- | Send a message.
sendP :: (Packable p (HeaderNContentData Empty r), MonadTransfer m)
      => p -> NetworkAddress -> r -> m ()
sendP packing addr msg = sendRaw addr $
    yield (HeaderNContentData Empty msg) =$= packMsg packing

sendHP :: (Packable p (HeaderNContentData h r), MonadTransfer m)
      => p -> NetworkAddress -> h -> r -> m ()
sendHP packing addr h msg = sendRaw addr $
    yield (HeaderNContentData h msg) =$= packMsg packing

sendRP :: (Packable p (HeaderNRawData h), MonadTransfer m)
      => p -> NetworkAddress -> h -> RawData -> m ()
sendRP packing addr h raw = sendRaw addr $
    yield (HeaderNRawData h raw) =$= packMsg packing


-- | Sends message to peer node.
replyP :: (Packable p (HeaderNContentData Empty r), MonadResponse m)
       => p -> r -> m ()
replyP packing msg = replyRaw $ yield (HeaderNContentData Empty msg) =$= packMsg packing

replyHP :: (Packable p (HeaderNContentData h r), MonadResponse m)
       => p -> h -> r -> m ()
replyHP packing h msg = replyRaw $ yield (HeaderNContentData h msg) =$= packMsg packing

replyRP :: (Packable p (HeaderNRawData h), MonadResponse m)
       => p -> h -> RawData -> m ()
replyRP packing h raw = replyRaw $ yield (HeaderNRawData h raw) =$= packMsg packing

type MonadListener m =
    ( MonadTransfer m
    , MonadIO m
    , MonadCatch m
    , WithNamedLogger m
    )

-- | Starts server.
listenP :: (Unpackable p (HeaderNNameData Empty), Unpackable p (HeaderNRawData Empty),
            MonadListener m)
        => p -> Binding -> [Listener p m] -> m ()
listenP packing binding listeners = listenHP packing binding $ convert <$> listeners
  where
    convert :: Listener p m -> ListenerH p Empty m
    convert (Listener f) = ListenerH $ f . second
    second (Empty, r) = r

listenHP :: (Unpackable p (HeaderNNameData h), Unpackable p (HeaderNRawData h),
             MonadListener m)
         => p -> Binding -> [ListenerH p h m] -> m ()
listenHP packing binding listeners =
    listenRP packing binding listeners (const $ return True)


listenRP :: (Unpackable p (HeaderNNameData h), Unpackable p (HeaderNRawData h),
             MonadListener m)
         => p -> Binding -> [ListenerH p h m] -> ListenerR h m -> m ()
listenRP packing binding listeners rawListener = listenRaw binding loop
  where
    loop = do
        hrM <- intangibleSink $ unpackMsg packing
        forM_ hrM $
            \(HeaderNRawData h raw) -> do
                peer <- lift peerAddr
                lift . commLog . logDebug $
                    sformat ("Received message from "%stext%", applying raw listener")
                        peer
                cont <- lift . invokeRawListenerSafe $ rawListener (h, raw)
                if cont
                    then processContent h
                    else do -- this is expected to work as fast as indexing
                            skip <- unpackMsg packing =$= CL.head
                            forM_ skip $
                                \(HeaderNRawData h0 _) ->
                                    let _ = [h, h0]  -- constraint h0 type
                                    in  loop

    processContent header = do
        nameM <- selector header
        case nameM of
            Nothing          -> lift . commLog . logWarning $
                sformat ("Unexpected end of incoming message")
            Just (Left name) -> lift . commLog . logWarning $
                sformat ("No listener with name "%stext%" defined") name
            Just (Right (ListenerH f)) -> do
                msgM <- unpackMsg packing =$= CL.head
                case msgM of
                    Nothing -> lift . commLog . logWarning $
                        sformat ("Unexpected end of incoming message")
                    Just (HeaderNContentData h r) ->
                        let _ = [h, header]  -- constraint on h type
                        in  do lift . invokeListenerSafe $ f (header, r)
                               loop

    selector header = chooseListener packing header getListenerNameH listeners

    invokeRawListenerSafe = handleAll $ \e -> do
        commLog . logError $ sformat ("Uncaught error in raw listener: "%shown) e
        return False

    invokeListenerSafe = handleAll $
        commLog . logError . sformat ("Uncaught error in listener: "%shown)

chooseListener :: (MonadListener m, Unpackable p (HeaderNNameData h))
               => p -> h -> (l m -> MessageName) -> [l m]
               -> Consumer ByteString (ResponseT m) (Maybe (Either MessageName (l m)))
chooseListener packing h getName listeners = do
    nameM <- intangibleSink $ unpackMsg packing
    forM nameM $
        \(HeaderNNameData h0 name) ->
            let _ = [h, h0]  -- constraint h0 type
            in  do  lift . commLog . logDebug $
                        sformat ("Got message: "%stext) name
                    return . maybe (Left name) Right $
                        listenersMap ^. at name
  where
    listenersMap = M.fromList [(getName li, li) | li <- listeners]


-- * Listeners

-- | Creates plain listener which accepts message.
data Listener p m =
    forall r . (Unpackable p (HeaderNContentData Empty r), Message r)
             => Listener (r -> ResponseT m ())

-- | Creates listener which accepts header and message.
data ListenerH p h m =
    forall r . (Unpackable p (HeaderNContentData h r), Message r)
             => ListenerH ((h, r) -> ResponseT m ())

-- | Creates listener which accepts header and raw data.
-- Returns, whether message souhld then be deserialized and passed to typed listener.
type ListenerR h m = (h, RawData) -> ResponseT m Bool


getListenerName :: Listener p m -> MessageName
getListenerName (Listener f) = messageName $ proxyOfArg f
  where
    proxyOfArg :: (a -> b) -> Proxy a
    proxyOfArg _ = Proxy

getListenerNameH :: ListenerH p h m -> MessageName
getListenerNameH (ListenerH f) = messageName $ proxyOfArg f
  where
    proxyOfArg :: ((h, a) -> b) -> Proxy a
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
