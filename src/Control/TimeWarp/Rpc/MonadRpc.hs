{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FunctionalDependencies    #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE PolyKinds                 #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE TypeOperators             #-}
{-# LANGUAGE UndecidableInstances      #-}

-- |
-- Module      : Control.TimeWarp.Rpc.MonadRpc
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

       , RpcRequest (..)
       , MessageId (..)

       , RpcOptions (..)
       , RpcOptionMessagePack
       , RpcOptionNoReturn

       , MonadRpc (..)
       , MonadMsgPackRpc
       , MonadMsgPackUdp
       , sendTimeout
       , submit
       , Method (..)
       , MethodTry (..)
       , methodMessageId
       , proxyOf
       , proxyOfArg
       , mkMethodTry
       , hoistMethod
       , RpcError (..)
       ) where

import           Control.Exception        (Exception)
import           Control.Monad            (void)
import           Control.Monad.Catch      (MonadCatch, MonadThrow (..), catchAll, try)
import           Control.Monad.Reader     (ReaderT (..))
import           Control.Monad.Trans      (lift)
import           Data.Monoid              ((<>))
import           Data.Proxy               (Proxy (..))
import           Data.Text                (Text)
import           Data.Text.Buildable      (Buildable (..))
import           GHC.Exts                 (Constraint)
import           GHC.Generics             (Generic)

import           Data.MessagePack.Object  (MessagePack (..))
import           Data.Time.Units          (Hour, TimeUnit)

import           Control.TimeWarp.Logging (LoggerNameBox (..))
import           Control.TimeWarp.Timed   (MonadTimed (timeout), fork_)


-- | Port number.
type Port = Int

-- | Host address.
type Host = Text

localhost :: Host
localhost = "127.0.0.1"

-- | Full node address.
type NetworkAddress = (Host, Port)

-- | Designates message type.
newtype MessageId = MessageId Int
    deriving (Eq, Ord, Show, Num, Generic)

instance MessagePack MessageId

-- | Defines name, response and expected error types of RPC-method to which data
-- of @req@ type can be delivered.
-- Expected error is the one which remote method can catch and send to client;
-- any other error in remote method raises `InternalError` at client side.
--
-- TODO: create instances of this class by TH.
class Exception (ExpectedError r) =>
      RpcRequest r where
    type Response r :: *

    type ExpectedError r :: *

    messageId :: Proxy r -> MessageId

-- | Declares requirements of RPC implementation.
class RpcOptions (o :: k) where
    type family RpcConstraints o r :: Constraint

instance RpcOptions '[] where
    type RpcConstraints '[] r = ()

-- | Options can be grouped into lists.
instance (RpcOptions o, RpcOptions os) => RpcOptions (o : os) where
    type RpcConstraints (o : os) r = (RpcConstraints o r, RpcConstraints os r)

data RpcOptionMessagePack
instance RpcOptions RpcOptionMessagePack where
    type RpcConstraints RpcOptionMessagePack r =
        ( MessagePack r
        , MessagePack (Response r)
        , MessagePack (ExpectedError r)
        )

data RpcOptionNoReturn
instance RpcOptions RpcOptionNoReturn where
    type RpcConstraints RpcOptionNoReturn r = Response r ~ ()

-- | Creates RPC-method.
data Method o m =
    forall r . (RpcRequest r, RpcConstraints o r) => Method (r -> m (Response r))

-- | Creates RPC-method, which catches exception of `err` type.
data MethodTry o m =
    forall r . (RpcRequest r, RpcConstraints o r) =>
    MethodTry (r -> m (Either (ExpectedError r) (Response r)))

mkMethodTry :: MonadCatch m => Method o m -> MethodTry o m
mkMethodTry (Method f) = MethodTry $ try . f

-- | Defines protocol of RPC layer.
class (MonadThrow m, RpcOptions o) => MonadRpc o m | m -> o where
    -- | Executes remote method call.
    send :: (RpcRequest r, RpcConstraints o r)
         => NetworkAddress -> r -> m (Response r)

    -- | Starts RPC server with a set of RPC methods.
    serve :: Port -> [Method o m] -> m ()

-- | Same as `send`, but allows to set up timeout for a call (see
-- `Control.TimeWarp.Timed.MonadTimed.timeout`).
sendTimeout
    :: (MonadTimed m, MonadRpc o m, RpcRequest r, RpcConstraints o r, TimeUnit t)
    => t -> NetworkAddress -> r -> m (Response r)
sendTimeout t addr = timeout t . send addr

-- | Similar to `send`, but doesn't wait for result.
submit
    :: (MonadCatch m, MonadTimed m, MonadRpc o m, RpcConstraints o r, RpcRequest r)
    => NetworkAddress -> r -> m ()
submit addr req =
    fork_ $ void (sendTimeout timeoutDelay addr req) `catchAll` \_ -> return ()
  where
    -- without timeout emulation has no choice but to hang on blackouts
    timeoutDelay = 1 :: Hour

methodMessageId :: Method o m -> MessageId
methodMessageId (Method f) = messageId $ proxyOfArg f

proxyOf :: a -> Proxy a
proxyOf _ = Proxy

proxyOfArg :: (a -> b) -> Proxy a
proxyOfArg _ = Proxy

hoistMethod :: (forall a. m a -> n a) -> Method o m -> Method o n
hoistMethod hoist' (Method f) = Method (hoist' . f)

-- * Instances

instance MonadRpc o m => MonadRpc o (ReaderT r m) where
    send addr req = lift $ send addr req

    serve port methods =
        ReaderT $ \r ->
            serve port (hoistMethod (`runReaderT` r) <$> methods)

deriving instance MonadRpc o m => MonadRpc o (LoggerNameBox m)

-- * Aliases

type MonadMsgPackRpc = MonadRpc RpcOptionMessagePack
type MonadMsgPackUdp = MonadRpc '[RpcOptionMessagePack, RpcOptionNoReturn]

-- * Exceptions

-- | Exception which can be thrown on `send` call.
data RpcError = -- | Can't find remote method on server's side die to
                -- network problems or lack of such service
                NetworkProblem Text
                -- | Error in RPC protocol with description, or server
                -- threw unserializable error
              | InternalError Text
                -- | Error thrown by server's method
              | forall e . (MessagePack e, Exception e) => ServerError e

instance Buildable RpcError where
    build (NetworkProblem msg) = "Network problem: " <> build msg
    build (InternalError msg)  = "Internal error: " <> build msg
    build (ServerError e)      = "Server reports error: " <> build (show e)

instance Show RpcError where
    show = show . build

instance Exception RpcError

