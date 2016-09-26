{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ViewPatterns          #-}

-- | This module contains `MonadRpc` typeclass which abstracts over
-- RPC communication.

module Control.TimeWarp.Rpc.MonadRpc
       ( Port
       , Host
       , NetworkAddress

       , MonadRpc (serve, execClient)
       , RpcType()
       , execClientTimeout
       , Method(..)
       , Client(..)
       , method
       , call
       , S.Server
       , S.ServerT
       , S.MethodType
       , C.RpcError(..)
       ) where

import           Control.Monad.Catch        (MonadCatch (catch),
                                             MonadThrow (throwM))
import           Control.Monad.Reader       (ReaderT (..))
import           Control.Monad.Trans        (lift)
import           Data.ByteString            (ByteString)

import           Data.MessagePack.Object    (MessagePack, Object (..), toObject)
import           Data.Time.Units            (TimeUnit)

import qualified Network.MessagePack.Client as C
import qualified Network.MessagePack.Server as S

import           Control.TimeWarp.Logging   (WithNamedLogger, LoggerNameBox (..))
import           Control.TimeWarp.Timed     (MonadTimed (timeout))

-- | Port number.
type Port = Int

-- | Host address.
type Host = ByteString

-- | Full node address.
type NetworkAddress = (Host, Port)


deriving instance (Monad m, WithNamedLogger m) => WithNamedLogger (S.ServerT m)

-- | Defines protocol of RPC layer.
class MonadThrow r => MonadRpc r where
    -- | Executes remote method call.
    execClient :: MessagePack a => NetworkAddress -> Client a -> r a

    -- | Starts RPC server with a set of RPC methods.
    serve :: Port -> [Method r] -> r ()

-- | Same as `execClient`, but allows to set up timeout for a call (see
-- `Control.TimeWarp.Timed.MonadTimed.timeout`).
execClientTimeout
    :: (MonadTimed m, MonadRpc m, MessagePack a, TimeUnit t)
    => t -> NetworkAddress -> Client a -> m a
execClientTimeout t addr = timeout t . execClient addr

-- * Client part

-- | Creates a function call. It accepts function name and arguments.
call :: RpcType t => String -> t
call name = rpcc name []

-- | Collects function name and arguments
-- (it's <https://hackage.haskell.org/package/msgpack-rpc-1.0.0/docs/Network-MessagePack-Client.html#v:call msgpack-rpc> implementation is hidden, need our own).
class RpcType t where
    rpcc :: String -> [Object] -> t

instance (RpcType t, MessagePack p) => RpcType (p -> t) where
    rpcc name objs p = rpcc name $ toObject p : objs

-- | Keeps function name and arguments.
data Client a where
    Client :: MessagePack a => String -> [Object] -> Client a

instance MessagePack o => RpcType (Client o) where
    rpcc name args = Client name (reverse args)

-- * Server part

-- | Keeps method definition.
data Method m = Method
    { methodName :: String
    , methodBody :: [Object] -> m Object
    }

-- | Creates method available for RPC-requests.
--   It accepts method name (which would be refered by clients)
--   and it's body.
method :: S.MethodType m f => String -> f -> Method m
method name f = Method
    { methodName = name
    , methodBody = S.toBody f
    }

instance Monad m => S.MethodType m Object where
    toBody res [] = return res
    toBody _   _  = error "Too many arguments!"

instance MonadThrow m => MonadThrow (S.ServerT m) where
    throwM = lift . throwM

instance MonadCatch m =>
         MonadCatch (S.ServerT m) where
    catch (S.ServerT action) handler =
        S.ServerT $ action `catch` (S.runServerT . handler)

instance MonadRpc m => MonadRpc (ReaderT r m) where
    execClient addr cli = lift $ execClient addr cli

    serve port methods = ReaderT $
                            \r -> serve port (convert r <$> methods)
      where
        convert :: Monad m => r -> Method (ReaderT r m) -> Method m
        convert r Method {..} =
            Method methodName (flip runReaderT r . methodBody)

deriving instance MonadRpc m => MonadRpc (LoggerNameBox m)
