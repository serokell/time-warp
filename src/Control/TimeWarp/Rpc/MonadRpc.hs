{-# LANGUAGE AllowAmbiguousTypes       #-}
{-# LANGUAGE BangPatterns              #-}
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
       , Mode (..)
       , IsMode (..)
       , ModeResponseMod

       , Send (..)
       , Rpc (..)
       , send
       , listen
       , call
       , serve
       , callTimeout
       , submit
       , Method (..)
       , MethodTry (..)
       , methodMessageId
       , proxyOf
       , proxyOfArg
       , mkMethodTry
       , hoistMethod
       , buildMethodsMap
       , RpcError (..)
       ) where

import Control.Exception (Exception)
import Control.Monad (void, when)
import Control.Monad.Catch (MonadCatch, catchAll, try)
import Data.Foldable (foldlM)
import qualified Data.Map as M
import Data.Monoid ((<>))
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text.Buildable (Buildable (..))
import Data.Typeable (Typeable)
import Data.Void (Void)
import Formatting (bprint, sformat, (%))
import qualified Formatting as F (build)
import GHC.Generics (Generic)
import Monad.Capabilities (CapsT, HasCaps, withCap)

import Data.MessagePack.Object (MessagePack (..))
import Data.Time.Units (Hour, TimeUnit)

import Control.TimeWarp.Timed (Timed, fork_, timeout)


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

instance Buildable MessageId where
    build (MessageId i) = bprint ("#"%F.build) i

instance MessagePack MessageId

-- | Defines name, response and expected error types of RPC-method to which data
-- of @req@ type can be delivered.
-- Expected error is the one which remote method can catch and send to client;
-- any other error in remote method raises `InternalError` at client side.
class (MessagePack r, MessagePack (Response r), MessagePack (ExpectedError r),
       Exception (ExpectedError r), Typeable r) =>
      RpcRequest r where
    type Response r :: *

    type ExpectedError r :: *
    type ExpectedError r = Void

    messageId :: Proxy r -> MessageId

-- | Submission mode.
data Mode
    = OneWay
      -- ^ No respond
    | RemoteCall
      -- ^ Response required

type family ModeResponseMod (mode :: Mode) r where
    ModeResponseMod 'OneWay r = ()
    ModeResponseMod 'RemoteCall r = r

class IsMode (mode :: Mode) where
    finaliseResponse :: Proxy mode -> r -> ModeResponseMod mode r
instance IsMode 'OneWay where
    finaliseResponse _ _ = ()
instance IsMode 'RemoteCall where
    finaliseResponse _ = id

-- | Creates RPC-method.
data Method (mode :: Mode) m =
    forall r. RpcRequest r => Method (r -> m (ModeResponseMod mode (Response r)))

-- | Creates RPC-method, which catches exception of `err` type.
data MethodTry (mode :: Mode) m =
    forall r. RpcRequest r =>
    MethodTry (r -> m (Either (ExpectedError r) (ModeResponseMod mode (Response r))))

mkMethodTry :: MonadCatch m => Method mode m -> MethodTry mode m
mkMethodTry (Method f) = MethodTry $ try . f

-- | Actions with one-way messages submission.
data Send m = Send
    { _send
        :: forall r. RpcRequest r
        => NetworkAddress -> r -> m ()
    , _listen
        :: Port -> [Method 'OneWay m] -> m ()
    }

-- | Actions with remote call messages passing.
data Rpc m = Rpc
    { _call
        :: forall r. RpcRequest r
        => NetworkAddress -> r -> m (Response r)
    , _serve
        :: Port -> [Method 'RemoteCall m] -> m ()
    }

-- | Sends a message.
send
    :: (HasCaps [Timed, Send] caps, RpcRequest r)
    => NetworkAddress -> r -> CapsT caps m ()
send addr msg = withCap $ \cap -> _send cap addr msg

-- | Starts listening on incoming messages.
listen
    :: (HasCaps [Timed, Send] caps, RpcRequest r)
    => Port -> [Method 'OneWay (CapsT caps m)] -> CapsT caps m ()
listen addr msg = withCap $ \cap -> _listen cap addr msg

-- | Executes remote method call.
call
    :: (HasCaps [Timed, Rpc] caps, RpcRequest r)
    => NetworkAddress -> r -> CapsT caps m (Response r)
call addr msg = withCap $ \cap -> _call cap addr msg

-- | Starts RPC server with a set of RPC methods.
serve
    :: (HasCaps [Timed, Rpc] caps, RpcRequest r)
    => Port -> [Method 'RemoteCall (CapsT caps m)] -> CapsT caps m ()
serve addr msg = withCap $ \cap -> _serve cap addr msg

-- | Same as `call`, but allows to set up timeout for a call (see
-- `Control.TimeWarp.Timed.MonadTimed.timeout`).
callTimeout
    :: (HasCaps [Timed, Rpc] caps, RpcRequest r, TimeUnit t)
    => t -> NetworkAddress -> r -> CapsT caps m (Response r)
callTimeout t addr = timeout t . call addr

-- | Similar to `call`, but doesn't wait for result.
submit
    :: (MonadCatch m, HasCaps [Timed, Rpc] caps, RpcRequest r)
    => NetworkAddress -> r -> CapsT caps m ()
submit addr req =
    fork_ $ void (callTimeout timeoutDelay addr req) `catchAll` \_ -> return ()
  where
    -- without timeout emulation has no choice but to hang on blackouts
    timeoutDelay = 1 :: Hour

methodMessageId :: Method mode m -> MessageId
methodMessageId (Method f) = messageId $ proxyOfArg f

proxyOf :: a -> Proxy a
proxyOf _ = Proxy

proxyOfArg :: (a -> b) -> Proxy a
proxyOfArg _ = Proxy

hoistMethod :: (forall a. m a -> n a) -> Method o m -> Method o n
hoistMethod hoist' (Method f) = Method (hoist' . f)

buildMethodsMap :: [Method o m] -> Either Text (M.Map MessageId (Method o m))
buildMethodsMap = foldlM addMethod mempty
  where
    addMethod !acc method = do
        let mid = methodMessageId method
        when (M.member mid acc) $
            Left $ sformat ("Several methods with "%F.build%" given") mid
        return $ M.insert mid method acc

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
