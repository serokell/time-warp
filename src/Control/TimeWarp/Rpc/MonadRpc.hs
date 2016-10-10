{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
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
       , localhost

       , Request (..)
       , Listener (..)
       , listener
       , getMethodName
       , proxyOf

       , MonadRpc (..)
       , sendTimeout
       , MonadResponse (..)
       , RpcError (..)
       ) where

import           Control.Exception          (Exception)
import           Control.Monad.Reader       (ReaderT (..), mapReaderT)
import           Control.Monad.Trans        (MonadTrans (..))
import           Data.ByteString            (ByteString)
import           Data.Monoid                ((<>))
import           Data.Proxy                 (Proxy (..), asProxyTypeOf)
import           Data.Text                  (Text)
import           Data.Text.Buildable        (Buildable (..))

import           Data.MessagePack.Object    (MessagePack (..))
import           Data.Time.Units            (TimeUnit)

import           Control.TimeWarp.Logging   (LoggerNameBox (..))
import           Control.TimeWarp.Timed     (MonadTimed (timeout))


-- * MonadRpc

-- | Defines protocol of RPC layer.
class (Monad m, MonadResponse (Response m))
    => MonadRpc m where
    -- | Defines monad, used in `Listener`s.
    type Response m :: * -> *

    -- | Sends a message at specified address.
    -- This method blocks until message fully delivered.
    send :: Request r
         => NetworkAddress -> r -> m ()

    -- | Starts RPC server with a set of RPC methods.
    listen :: Port -> [Listener (Response m)] -> m ()

    -- | Lifts monad rpc
    liftR :: m a -> (Response m) a

    -- | Closes connection to specified node, if exists.
    close :: NetworkAddress -> m ()

-- | Same as `execClient`, but allows to set up timeout for a call (see
-- `Control.TimeWarp.Timed.MonadTimed.timeout`).
sendTimeout
    :: (MonadTimed m, MonadRpc m, Request r, TimeUnit t)
    => t -> NetworkAddress -> r -> m ()
sendTimeout t addr = timeout t . send addr

-- | Creates simple listener, which uses same monad as environment.
-- Return value would be send back to companion.
--
-- TODO: how not to send if response is `()`?
listener :: (MonadRpc m, Request r, Request a)
         => (r -> m a) -> Listener (Response m)
listener f = Listener $ \req -> liftR (f req) >>= reply


-- * MonadResponse

-- | When got a request from other node (it is further called /companion/),
-- specifies actions related to communication with that node.
class Monad m => MonadResponse m where
    -- | Get /companion/'s address.
    reply :: Request r => r -> m ()

    closeCompanion :: m ()


-- * Listeners

-- | Creates RPC-method.
data Listener m =
    forall r . Request r => Listener (r -> m ())

{-
-- | Default instance of `MonadResponse`.
newtype ResponseT m a = ResponseT
    { getResponseT :: ReaderT NetworkAddress m a  -- ^ keeps /companion/ address
    } deriving (Functor, Applicative, Monad,
                MonadIO, MonadThrow, MonadCatch, MonadMask,
                MonadTrans, MonadState s,
                MonadTimed, MonadRpc)

type instance ThreadId (ResponseT m) = ThreadId m

runResponseT :: ResponseT m a -> NetworkAddress -> m a
runResponseT = runReaderT . getResponseT
-}

getMethodName :: Listener m -> String
getMethodName (Listener f) = let rp = Proxy :: Request r => Proxy r
                                 -- make rp contain type of f's argument
                                 _ = f $ undefined `asProxyTypeOf` rp
                             in  methodName rp

proxyOf :: a -> Proxy a
proxyOf _ = Proxy


-- * Related datatypes

-- | Port number.
type Port = Int

-- | Host address.
type Host = ByteString

localhost :: Host
localhost = "127.0.0.1"

-- | Full node address.
type NetworkAddress = (Host, Port)

-- | Defines method name corresponding to this request type.
-- TODO: use ready way to get datatype's name
class MessagePack r => Request r where
    methodName :: Proxy r -> String

instance Request () where
    methodName _ = "()"


-- * Exceptions

-- | Exception which can be thrown on `send` call.
data RpcError = -- | Can't find remote method on server's side die to
                -- network problems or lack of such service
                NetworkProblem Text
                -- | Error in RPC protocol with description, or server
                -- threw unserializable error
              | InternalError Text

instance Buildable RpcError where
    build (NetworkProblem msg) = "Network problem: " <> build msg
    build (InternalError msg)  = "Internal error: " <> build msg

instance Show RpcError where
    show = show . build

instance Exception RpcError


-- * Instances

instance MonadRpc m => MonadRpc (ReaderT r m) where
    type Response (ReaderT r m) = ReaderT r (Response m)

    send addr req = lift $ send addr req

    listen port listeners = ReaderT $
                            \r -> listen port (convert r <$> listeners)
      where
        convert r (Listener f) =
            Listener $ flip runReaderT r . f

    liftR = mapReaderT liftR

    close = lift . close

instance MonadResponse m => MonadResponse (ReaderT r m) where
    reply = lift . reply

    closeCompanion = lift $ closeCompanion

{-
instance MonadReader r m => MonadReader r (ResponseT m) where
    ask = ResponseT $ lift ask
    local how (ResponseT m) = ResponseT $ mapReaderT (local how) m
    reader f = ResponseT . lift $ reader f
-}

deriving instance MonadResponse m => MonadResponse (LoggerNameBox m)

instance MonadRpc m => MonadRpc (LoggerNameBox m) where
    type Response (LoggerNameBox m) = LoggerNameBox (Response m)

    send addr req = LoggerNameBox $ send addr req

    listen port listeners = LoggerNameBox $ listen port (convert <$> listeners)
      where
        convert (Listener f) = Listener $ loggerNameBoxEntry . f

    liftR = LoggerNameBox . liftR . loggerNameBoxEntry

    close = LoggerNameBox . close
