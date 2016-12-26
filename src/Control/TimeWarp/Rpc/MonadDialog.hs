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

       -- * ForkStrategy
       , ForkStrategy (..)

       -- * Communication methods
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

       -- * Listeners
       , Listener (..)
       , ListenerH (..)
       , ListenerR
       , getListenerName
       , getListenerNameH

       -- * Misc
       , MonadListener
       ) where

import           Control.Lens                       (at, iso, (.~), (^.), _2)
import           Control.Monad                      (void, when)
import           Control.Monad.Base                 (MonadBase (..))
import           Control.Monad.Catch                (MonadCatch, MonadMask, MonadThrow,
                                                     handleAll)
import           Control.Monad.Morph                (hoist)
import           Control.Monad.Reader               (MonadReader (ask, local),
                                                     ReaderT (..))
import           Control.Monad.State                (MonadState)
import           Control.Monad.Trans                (MonadIO, MonadTrans (..))
import           Control.Monad.Trans.Control        (ComposeSt, MonadBaseControl (..),
                                                     MonadTransControl (..), StM,
                                                     defaultLiftBaseWith, defaultLiftWith,
                                                     defaultRestoreM, defaultRestoreT)
import           Data.ByteString                    (ByteString)
import           Data.Conduit                       (Conduit, yield, (=$=))
import qualified Data.Conduit.List                  as CL
import           Data.Map                           as M
import           Data.Proxy                         (Proxy (..))
import           Formatting                         (sformat, shown, stext, (%))
import           System.Wlog                        (CanLog, HasLoggerName,
                                                     LoggerNameBox (..), WithLogger,
                                                     logDebug, logError, logWarning)

import           Serokell.Util.Lens                 (WrappedM (..))

import           Control.TimeWarp.Rpc.Message       (ContentData (..), Message (..),
                                                     MessageName, NameData (..),
                                                     Packable (..), RawData (..),
                                                     Unpackable (..), WithHeaderData (..),
                                                     unpackMsg)
import           Control.TimeWarp.Rpc.MonadTransfer (Binding,
                                                     MonadResponse (peerAddr, replyRaw),
                                                     MonadTransfer (..), NetworkAddress,
                                                     ResponseT (..), commLog)
import           Control.TimeWarp.Timed             (MonadTimed, ThreadId, fork_)


-- * Related datatypes

data ForkStrategy s = ForkStrategy
    { withForkStrategy :: forall m . (MonadIO m, MonadTimed m)
                       => s -> m () -> m ()
    }


-- * MonadDialog

-- | Defines communication based on messages.
-- It allows to specify service data (/header/) for use by overlying protocols.
class MonadTransfer s m => MonadDialog s p m | m -> p, m -> s where
    packingType     :: m p
    forkStrategy    :: m (ForkStrategy MessageName)
    setForkStrategy :: ForkStrategy MessageName -> m a -> m a

-- * Communication methods

-- ** Helpers

packMsg' :: (Packable p r, MonadDialog s p m, MonadThrow m) => Conduit r m ByteString
packMsg' = lift packingType >>= packMsg


-- $monad-dialog-funcs
-- Functions differ by suffix, meanings are following:
--
--  * /No suffix/ - operates with plain message (TODO: weaken `Packable` constraints)
--
--  * H - operates with message with header
--
--  * R - operates with message in raw form with header

-- ** Send functions

-- | Send message of arbitrary structure
doSend :: (Packable p r, MonadDialog s p m, MonadThrow m)
       => NetworkAddress -> r -> m ()
doSend addr r = sendRaw addr $ yield r =$= packMsg'

-- | Send plain message
send :: (Packable p (WithHeaderData () (ContentData r)), MonadDialog s p m, MonadThrow m)
     => NetworkAddress -> r -> m ()
send addr msg = doSend addr $ WithHeaderData () (ContentData msg)

-- | Send message with header
sendH :: (Packable p (WithHeaderData h (ContentData r)), MonadDialog s p m, MonadThrow m)
      => NetworkAddress -> h -> r -> m ()
sendH addr h msg = doSend addr $ WithHeaderData h (ContentData msg)

-- | Send message given in raw form
sendR :: (Packable p (WithHeaderData h RawData), MonadDialog s p m, MonadThrow m)
      => NetworkAddress -> h -> RawData -> m ()
sendR addr h raw = doSend addr $ WithHeaderData h raw


-- ** Reply functions

-- | Reply to peer node with message of arbitrary structure
doReply :: (Packable p r, MonadDialog s p m, MonadResponse s m, MonadThrow m)
        => r -> m ()
doReply r = replyRaw $ yield r =$= packMsg'

-- | Sends message to peer node.
reply :: (Packable p (WithHeaderData () (ContentData r)), MonadDialog s p m,
          MonadResponse s m, MonadThrow m)
      => r -> m ()
reply msg = doReply $ WithHeaderData () (ContentData msg)

-- | Sends message with given header to peer node.
replyH :: (Packable p (WithHeaderData h (ContentData r)), MonadDialog s p m,
           MonadResponse s m, MonadThrow m)
       => h -> r -> m ()
replyH h msg = doReply $ WithHeaderData h (ContentData msg)

-- | Sends message with given header and message content in raw form to peer node.
replyR :: (Packable p (WithHeaderData h RawData), MonadDialog s p m,
           MonadResponse s m, MonadThrow m)
       => h -> RawData -> m ()
replyR h raw = doReply $ WithHeaderData h raw

-- Those @m@ looks like waterfall :3
type MonadListener  s m =
    ( MonadIO       m
    , MonadMask     m
    , MonadTimed    m
    , MonadTransfer s m
    , WithLogger    m
    )

-- | Starts server with given set of listeners.
listen :: (Unpackable p (WithHeaderData () RawData),Unpackable p NameData,
           MonadListener s m, MonadDialog s p m)
       => Binding -> [Listener s p m] -> m (m ())
listen binding listeners = listenH binding $ convert <$> listeners
  where
    convert :: Listener s p m -> ListenerH s p () m
    convert (Listener f) = ListenerH $ f . second
    second ((), r) = r

-- | Starts server with given set of listeners, which allow to read both header and
-- content of received message.
listenH :: (Unpackable p (WithHeaderData h RawData), Unpackable p NameData,
            MonadListener s m, MonadDialog s p m)
        => Binding -> [ListenerH s p h m] -> m (m ())
listenH binding listeners =
    listenR binding listeners (const $ return True)

-- | Starts server with given /raw listener/ and set of /typed listeners/.
-- First, raw listener is applied, it allows to read header and content in raw form of
-- received message.
-- If raw listener returned `True`, then processing continues with given typed listeners
-- in the way defined in `listenH`.
listenR :: (Unpackable p (WithHeaderData h RawData),Unpackable p NameData,
            MonadListener s m, MonadDialog s p m)
        => Binding -> [ListenerH s p h m] -> ListenerR s h m -> m (m ())
listenR binding listeners rawListener = do
    packing <- packingType
    forking <- forkStrategy
    listenRaw binding $ handleAll handleE $
        unpackMsg packing =$= CL.mapM  (processContent packing)
                          =$= CL.mapM_ (uncurry $ withForkStrategy forking)
  where
    processContent packing msg = do
        WithHeaderData header raw <- extractMsgPart packing msg
        NameData name             <- extractMsgPart packing msg

        case listenersMap ^. at name of
            Nothing -> do
                commLog . logWarning $
                    sformat ("No listener with name "%stext%" defined") name
                putDownstream name . void $
                    invokeRawListenerSafe $ rawListener (header, raw)

            Just (ListenerH f) -> do
                ContentData r <- extractMsgPart packing msg
                putDownstream name $ do
                    cont <- invokeRawListenerSafe $ rawListener (header, raw)
                    peer <- peerAddr
                    when cont $ do
                        commLog . logDebug $
                            sformat ("Got message from "%stext%": "%stext)
                            peer (formatMessage r)
                        invokeListenerSafe name $ f (header, r)

    handleE e = lift . commLog . logWarning $
                    sformat ("Error parsing message: " % shown) e

    -- TODO: check for duplicates
    listenersMap = M.fromList [(getListenerNameH li, li) | li <- listeners]

    invokeRawListenerSafe = handleAll $ \e -> do
        commLog . logError $ sformat ("Uncaught error in raw listener: "%shown) e
        return False

    invokeListenerSafe name = handleAll $
        commLog . logError . sformat ("Uncaught error in listener "%shown%": "%shown) name

    putDownstream = curry return

-- * Listeners

-- | Creates plain listener which accepts message.
data Listener s p m =
    forall r . (Unpackable p (ContentData r), Message r)
             => Listener (r -> ResponseT s m ())

-- | Creates listener which accepts header and message.
data ListenerH s p h m =
    forall r . (Unpackable p (ContentData r), Message r)
             => ListenerH ((h, r) -> ResponseT s m ())

-- | Creates listener which accepts header and raw data.
-- Returns, whether message souhld then be deserialized and passed to typed listener.
type ListenerR s h m = (h, RawData) -> ResponseT s m Bool

-- | Gets name of message type, acceptable by this listener.
getListenerName :: Listener s p m -> MessageName
getListenerName (Listener f) = messageName $ proxyOfArg f
  where
    proxyOfArg :: (a -> b) -> Proxy a
    proxyOfArg _ = Proxy

-- | Gets name of message type, acceptable by this listener.
getListenerNameH :: ListenerH s p h m -> MessageName
getListenerNameH (ListenerH f) = messageName $ proxyOfArg f
  where
    proxyOfArg :: ((h, a) -> b) -> Proxy a
    proxyOfArg _ = Proxy


-- * Default instance of MonadDialog

-- | Default implementation of `MonadDialog`.
-- Keeps packing type in context, allowing to use the same serialization strategy
-- all over the code without extra boilerplate.
newtype Dialog p m a = Dialog
    { getDialog :: ReaderT (p, ForkStrategy MessageName) m a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadTrans,
                MonadThrow, MonadCatch, MonadMask,
                MonadState s, CanLog, HasLoggerName, MonadTimed)

-- | Runs given `Dialog`.
runDialog :: p -> Dialog p m a -> m a
runDialog p = flip runReaderT (p, ForkStrategy $ const fork_) . getDialog

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
    type UnwrappedM (Dialog p m) = ReaderT (p, ForkStrategy MessageName) m
    _WrappedM = iso getDialog Dialog

instance MonadTransfer s m => MonadTransfer s (Dialog p m) where

instance MonadTransfer s m => MonadDialog s p (Dialog p m) where
    packingType = fst <$> Dialog ask
    forkStrategy = snd <$> Dialog ask
    setForkStrategy fs = Dialog . local (_2 .~ fs) . getDialog


-- * Instances

instance MonadDialog s p m => MonadDialog s p (ReaderT r m) where
    packingType = lift packingType
    forkStrategy = lift forkStrategy
    setForkStrategy fs = hoist $ setForkStrategy fs

deriving instance MonadDialog s p m => MonadDialog s p (LoggerNameBox m)

deriving instance MonadDialog s p m => MonadDialog s p (ResponseT s0 m)
