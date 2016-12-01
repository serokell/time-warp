{-# LANGUAGE ConstraintKinds           #-}
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
-- Maintainer  : Serokell <hi@serokell.io>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module defines `Dialog` monad, which is add-on over `Transfer` and allows to
-- send/receive whole messages, where serialization strategy could be defined in
-- arbitrary way.
--
-- For `Dialog`, `send` function is trivial; `listen` function infinitelly captures
-- messages from input stream, processing them in separate thread then.
--
--
-- Mainly, following structure of message is currently supported:
-- [header, name, content]
-- where /name/ uniquely defines type of message.
--
-- Given message could be deserealized as sum of header and raw data;
-- then user can just send the message further, or deserialize and process
-- message's content.

module Control.TimeWarp.Rpc.MonadDialog
       (
       -- * MonadDialog
         MonadDialog (..)

       -- * Dialog
       , Dialog (..)
       , runDialog

       -- * Communication methods
       -- ** For MonadDialog
       -- $monad-dialog-funcs
       , send
       , sendH
       , sendR
       , listen
       , listenH
       , listenR
       , reply
       , replyH
       , replyR

       -- ** Packing type manually defined
       -- $manual-packing-funcs
       , sendP
       , sendHP
       , sendRP
       , listenP
       , listenHP
       , listenRP
       , replyP
       , replyHP
       , replyRP

       -- * Listeners
       , Listener (..)
       , ListenerH (..)
       , ListenerR
       , getListenerName
       , getListenerNameH

       -- * Misc
       , MonadListener
       ) where

import           Control.Lens                       (at, iso, (^.))
import           Control.Monad                      (forM, forM_, void, when)
import           Control.Monad.Base                 (MonadBase (..))
import           Control.Monad.Catch                (MonadCatch, MonadMask, MonadThrow,
                                                     handleAll)
import           Control.Monad.Reader               (MonadReader (ask), ReaderT (..))
import           Control.Monad.State                (MonadState)
import           Control.Monad.Trans                (MonadIO, MonadTrans (..))
import           Control.Monad.Trans.Control        (ComposeSt, MonadBaseControl (..),
                                                     MonadTransControl (..), StM,
                                                     defaultLiftBaseWith, defaultLiftWith,
                                                     defaultRestoreM, defaultRestoreT)
import           Data.ByteString                    (ByteString)
import           Data.Conduit                       (Consumer, yield, (=$=))
import           Data.Conduit.List                  as CL
import           Data.Map                           as M
import           Data.Proxy                         (Proxy (..))
import           Formatting                         (sformat, shown, stext, (%))
import           System.Wlog                        (CanLog, HasLoggerName,
                                                     LoggerNameBox (..), WithLogger,
                                                     logDebug, logError, logWarning)

import           Serokell.Util.Lens                 (WrappedM (..))

import           Control.TimeWarp.Rpc.Message       (HeaderNContentData (..),
                                                     HeaderNNameData (..),
                                                     HeaderNRawData (..), Message (..),
                                                     MessageName, Packable (..),
                                                     RawData (..), Unpackable (..),
                                                     intangibleSink)
import           Control.TimeWarp.Rpc.MonadTransfer (Binding,
                                                     MonadResponse (peerAddr, replyRaw),
                                                     MonadTransfer (..), NetworkAddress,
                                                     ResponseT (..), commLog)
import           Control.TimeWarp.Timed             (MonadTimed, ThreadId, fork_)


-- * MonadRpc

-- | Defines communication based on messages.
-- It allows to specify service data (/header/) for use by overlying protocols.
class MonadTransfer m => MonadDialog p m | m -> p where
    packingType :: m p

-- * Communication methods

-- ** For MonadDialog
-- $monad-dialog-funcs
-- Functions differ by suffix, meanings are following:
--
--  * /No suffix/ - operates with plain message (TODO: weaken `Packable` constraints)
--
--  * H - operates with message with header
--
--  * R - operates with message in raw form with header

-- | Sends a message.
send :: (Packable p (HeaderNContentData () r), MonadDialog p m, MonadThrow m)
     => NetworkAddress -> r -> m ()
send addr msg = packingType >>= \p -> sendP p addr msg

-- | Sends a message with given header.
sendH :: (Packable p (HeaderNContentData h r), MonadDialog p m, MonadThrow m)
      => NetworkAddress -> h -> r -> m ()
sendH addr h msg = packingType >>= \p -> sendHP p addr h msg

-- | Sends a message with given header and message content in raw form.
sendR :: (Packable p (HeaderNRawData h), MonadDialog p m, MonadThrow m)
      => NetworkAddress -> h -> RawData -> m ()
sendR addr h raw = packingType >>= \p -> sendRP p addr h raw

-- | Sends message to peer node.
reply :: (Packable p (HeaderNContentData () r), MonadDialog p m, MonadResponse m, MonadThrow m)
      => r -> m ()
reply msg = packingType >>= \p -> replyP p msg

-- | Sends message with given header to peer node.
replyH :: (Packable p (HeaderNContentData h r), MonadDialog p m, MonadResponse m, MonadThrow m)
       => h -> r -> m ()
replyH h msg = packingType >>= \p -> replyHP p h msg

-- | Sends message with given header and message content in raw form to peer node.
replyR :: (Packable p (HeaderNRawData h), MonadDialog p m, MonadResponse m, MonadThrow m)
       => h -> RawData -> m ()
replyR h raw = packingType >>= \p -> replyRP p h raw

-- | Starts server with given set of listeners.
listen :: (Unpackable p (HeaderNNameData ()), Unpackable p (HeaderNRawData ()),
           MonadListener m, MonadDialog p m)
       => Binding -> [Listener p m] -> m (m ())
listen binding listeners =
    packingType >>= \p -> listenP p binding listeners

-- | Starts server with given set of listeners, which allow to read both header and
-- content of received message.
listenH :: (Unpackable p (HeaderNNameData h), Unpackable p (HeaderNRawData h),
            MonadListener m, MonadDialog p m)
        => Binding -> [ListenerH p h m] -> m (m ())
listenH binding listeners =
    packingType >>= \p -> listenHP p binding listeners

-- | Starts server with given /raw listener/ and set of /typed listeners/.
-- First, raw listener is applied, it allows to read header and content in raw form of
-- received message.
-- If raw listener returned `True`, then processing continues with given typed listeners
-- in the way defined in `listenH`.
listenR :: (Unpackable p (HeaderNNameData h), Unpackable p (HeaderNRawData h),
            MonadListener m, MonadDialog p m)
        => Binding -> [ListenerH p h m] -> ListenerR h m -> m (m ())
listenR binding listeners rawListener =
    packingType >>= \p -> listenRP p binding listeners rawListener


-- ** Packing type manually defined
-- $manual-packing-funcs
-- These functions are analogies to ones without /P/ suffix, but accept packing type as
-- argument.

-- | Similar to `send`.
sendP :: (Packable p (HeaderNContentData () r), MonadTransfer m, MonadThrow m)
      => p -> NetworkAddress -> r -> m ()
sendP packing addr msg = sendRaw addr $
    yield (HeaderNContentData () msg) =$= packMsg packing

-- | Similar to `sendH`.
sendHP :: (Packable p (HeaderNContentData h r), MonadTransfer m, MonadThrow m)
      => p -> NetworkAddress -> h -> r -> m ()
sendHP packing addr h msg = sendRaw addr $
        yield (HeaderNContentData h msg) =$= packMsg packing

-- | Similar to `sendR`.
sendRP :: (Packable p (HeaderNRawData h), MonadTransfer m, MonadThrow m)
      => p -> NetworkAddress -> h -> RawData -> m ()
sendRP packing addr h raw = sendRaw addr $
    yield (HeaderNRawData h raw) =$= packMsg packing


-- | Similar to `reply`.
replyP :: (Packable p (HeaderNContentData () r), MonadResponse m, MonadThrow m)
       => p -> r -> m ()
replyP packing msg = replyRaw $ yield (HeaderNContentData () msg) =$= packMsg packing

-- | Similar to `replyH`.
replyHP :: (Packable p (HeaderNContentData h r), MonadResponse m, MonadThrow m)
       => p -> h -> r -> m ()
replyHP packing h msg = replyRaw $ yield (HeaderNContentData h msg) =$= packMsg packing

-- | Similar to `replyR`.
replyRP :: (Packable p (HeaderNRawData h), MonadResponse m, MonadThrow m)
       => p -> h -> RawData -> m ()
replyRP packing h raw = replyRaw $ yield (HeaderNRawData h raw) =$= packMsg packing

-- Those @m@ looks like waterfall :3
type MonadListener  m =
    ( MonadIO       m
    , MonadMask     m
    , MonadTimed    m
    , MonadTransfer m
    , WithLogger    m
    )

-- | Similar to `listen`.
listenP :: (Unpackable p (HeaderNNameData ()), Unpackable p (HeaderNRawData ()),
            MonadListener m)
        => p -> Binding -> [Listener p m] -> m (m ())
listenP packing binding listeners = listenHP packing binding $ convert <$> listeners
  where
    convert :: Listener p m -> ListenerH p () m
    convert (Listener f) = ListenerH $ f . second
    second ((), r) = r

-- | Similar to `listenH`.
listenHP :: (Unpackable p (HeaderNNameData h), Unpackable p (HeaderNRawData h),
             MonadListener m)
         => p -> Binding -> [ListenerH p h m] -> m (m ())
listenHP packing binding listeners =
    listenRP packing binding listeners (const $ return True)

-- | Similar to `listenR`.
listenRP :: (Unpackable p (HeaderNNameData h), Unpackable p (HeaderNRawData h),
             MonadListener m)
         => p -> Binding -> [ListenerH p h m] -> ListenerR h m -> m (m ())
listenRP packing binding listeners rawListener = listenRaw binding loop
  where
    loop = do
        hrM <- intangibleSink $ unpackMsg packing
        forM_ hrM $
            \(HeaderNRawData h raw) -> processContent h raw

    processContent header raw = do
        nameM <- selector header
        case nameM of
            Nothing ->
                lift . commLog . logWarning $
                    sformat "Unexpected end of incoming message"
            Just (name, Nothing) -> do
                lift . fork_ . void $ invokeRawListenerSafe $ rawListener (header, raw)
                lift . commLog . logWarning $
                    sformat ("No listener with name "%stext%" defined") name
                skipMsgAndGo header
            Just (name, Just (ListenerH f)) -> do
                msgM <- unpackMsg packing =$= CL.head
                case msgM of
                    Nothing -> lift . commLog . logWarning $
                        sformat "Unexpected end of incoming message"
                    Just (HeaderNContentData h r) ->
                        let _ = [h, header]  -- constraint on h type
                        in do
                            lift . fork_ $ do
                                cont <- invokeRawListenerSafe $ rawListener (header, raw)
                                peer <- peerAddr
                                when cont $ do
                                    lift . commLog . logDebug $
                                        sformat ("Got message from "%stext%": "%stext)
                                        peer (formatMessage r)
                                    invokeListenerSafe name $ f (header, r)
                            loop

    selector header = chooseListener packing header getListenerNameH listeners

    skipMsgAndGo h = do
        -- this is expected to work as fast as indexing
        skip <- unpackMsg packing =$= CL.head
        forM_ skip $
            \(HeaderNRawData h0 _) ->
                let _ = [h, h0]  -- constraint h0 type
                in  loop


    invokeRawListenerSafe = handleAll $ \e -> do
        commLog . logError $ sformat ("Uncaught error in raw listener: "%shown) e
        return False

    invokeListenerSafe name = handleAll $
        commLog . logError . sformat ("Uncaught error in listener "%shown%": "%shown) name

chooseListener :: (MonadListener m, Unpackable p (HeaderNNameData h))
               => p -> h -> (l m -> MessageName) -> [l m]
               -> Consumer ByteString (ResponseT m) (Maybe (MessageName, Maybe (l m)))
chooseListener packing h getName listeners = do
    nameM <- intangibleSink $ unpackMsg packing
    forM nameM $
        \(HeaderNNameData h0 name) ->
            let _ = [h, h0]  -- constraint h0 type
            in  return (name, listenersMap ^. at name)
  where
    listenersMap = M.fromList [(getName li, li) | li <- listeners]


-- * Listeners

-- | Creates plain listener which accepts message.
data Listener p m =
    forall r . (Unpackable p (HeaderNContentData () r), Message r)
             => Listener (r -> ResponseT m ())

-- | Creates listener which accepts header and message.
data ListenerH p h m =
    forall r . (Unpackable p (HeaderNContentData h r), Message r)
             => ListenerH ((h, r) -> ResponseT m ())

-- | Creates listener which accepts header and raw data.
-- Returns, whether message souhld then be deserialized and passed to typed listener.
type ListenerR h m = (h, RawData) -> ResponseT m Bool

-- | Gets name of message type, acceptable by this listener.
getListenerName :: Listener p m -> MessageName
getListenerName (Listener f) = messageName $ proxyOfArg f
  where
    proxyOfArg :: (a -> b) -> Proxy a
    proxyOfArg _ = Proxy

-- | Gets name of message type, acceptable by this listener.
getListenerNameH :: ListenerH p h m -> MessageName
getListenerNameH (ListenerH f) = messageName $ proxyOfArg f
  where
    proxyOfArg :: ((h, a) -> b) -> Proxy a
    proxyOfArg _ = Proxy


-- * Default instance of MonadDialog

-- | Default implementation of `MonadDialog`.
-- Keeps packing type in context, allowing to use the same serialization strategy
-- all over the code without extra boilerplate.
newtype Dialog p m a = Dialog
    { getDialog :: ReaderT p m a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadTrans,
                MonadThrow, MonadCatch, MonadMask,
                MonadState s, CanLog, HasLoggerName, MonadTimed)

-- | Runs given `Dialog`.
runDialog :: p -> Dialog p m a -> m a
runDialog p = flip runReaderT p . getDialog

instance MonadBase IO m => MonadBase IO (Dialog p m) where
    liftBase = lift . liftBase

instance MonadTransControl (Dialog p) where
    type StT (Dialog p) a = StT (ReaderT p) a
    liftWith = defaultLiftWith Dialog getDialog
    restoreT = defaultRestoreT Dialog

instance MonadBaseControl IO m => MonadBaseControl IO (Dialog p m) where
    type StM (Dialog p m) a = ComposeSt (Dialog p) m a
    liftBaseWith     = defaultLiftBaseWith
    restoreM         = defaultRestoreM

type instance ThreadId (Dialog p m) = ThreadId m

instance Monad m => WrappedM (Dialog p m) where
    type UnwrappedM (Dialog p m) = ReaderT p m
    _WrappedM = iso getDialog Dialog

instance MonadTransfer m => MonadTransfer (Dialog p m) where

instance MonadTransfer m => MonadDialog p (Dialog p m) where
    packingType = Dialog ask


-- * Instances

instance MonadDialog p m => MonadDialog p (ReaderT r m) where
    packingType = lift packingType

deriving instance MonadDialog p m => MonadDialog p (LoggerNameBox m)

deriving instance MonadDialog p m => MonadDialog p (ResponseT m)
