{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}

{-# LANGUAGE ScopedTypeVariables   #-}

-- |
-- Module      : Control.TimeWarp.Rpc.MsgPackRpc
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module contains implementation of `MonadRpc` for real mode
-- (network, time- and thread-management capabilities provided by OS are used).

module Control.TimeWarp.Rpc.MsgPackRpc
       ( MsgPackRpc
       , runMsgPackRpc
       ) where

import qualified Control.Concurrent                as C
import           Control.Monad.Base                (MonadBase)
import           Control.Monad.Catch               (MonadCatch, MonadMask,
                                                    MonadThrow (..),
                                                    catches, Handler (..))
import           Control.Monad.Trans               (MonadIO (..))
import           Control.Monad.Trans.Control       (MonadBaseControl, StM,
                                                    liftBaseWith, restoreM)
import           Data.List                         (isPrefixOf)
import qualified Data.Text                         as T
import           GHC.IO.Exception                  (IOException (IOError), ioe_errno)
import           Formatting                        (sformat, shown, (%))

import           Data.Conduit.Serialization.Binary (ParseError)
import           Data.MessagePack.Object           (fromObject)
import qualified Network.MessagePack.Client        as C
import qualified Network.MessagePack.Server        as S

import           Control.TimeWarp.Rpc.MonadRpc     (Listener (..), MonadRpc (..),
                                                    Request (..), getMethodName,
                                                    proxyOf, RpcError (..))
import           Control.TimeWarp.Timed            (MonadTimed, TimedIO, ThreadId,
                                                    runTimedIO, fork_)

-- | Wrapper over `Control.TimeWarp.Timed.TimedIO`, which implements `MonadRpc`
-- using <https://hackage.haskell.org/package/msgpack-rpc-1.0.0 msgpack-rpc>.
newtype MsgPackRpc a = MsgPackRpc
    { -- | Launches distributed scenario using real network, threads and time.
      unwrapMsgPackRpc :: TimedIO a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadBase IO,
                MonadThrow, MonadCatch, MonadMask, MonadTimed)

runMsgPackRpc :: MsgPackRpc a -> IO a
runMsgPackRpc = runTimedIO . unwrapMsgPackRpc

-- Data which server sends to client.
-- message about unexpected error | (expected error | result)
instance MonadRpc MsgPackRpc where
    send (addr, port) req = liftIO $ do
        handleExc $ C.execClient addr port $ do
            () <- C.call name req
            return ()
      where
        name = methodName $ proxyOf req

        handleExc :: IO a -> IO a
        handleExc = flip catches [ Handler connRefusedH
                                 , Handler rpcErrorH
                                 , Handler noSuchMethodH
                                 ]

        connRefusedH e@IOError{..} =
            if ioe_errno == Just 111
            then throwM $ NetworkProblem "Connection refused"
            else throwM e

        rpcErrorH :: MonadThrow m => C.RpcError -> m a
        rpcErrorH (C.ResultTypeError  s) = throwM $ InternalError $ T.pack s
        rpcErrorH (C.ProtocolError    s) = throwM $ InternalError $ T.pack s
        rpcErrorH (C.ServerError errObj) =
            case fromObject errObj of
                Nothing  -> throwM $ InternalError "Failed to deserialize error msg"
                Just err -> if "method" `isPrefixOf` err
                            then throwM $ NetworkProblem noSuchMethodMsg
                            else throwM $ InternalError $ T.pack err

        -- when server has no needed method, somehow it ends with `ParseException`,
        -- not `C.ServerError`
        noSuchMethodH :: MonadThrow m => ParseError -> m a
        noSuchMethodH _ = throwM $ NetworkProblem noSuchMethodMsg

        noSuchMethodMsg = sformat ("No method " % shown % " found at port " % shown)
                              name port

    listen port methods = S.serve port $ convertMethod <$> methods
      where
        convertMethod :: Listener MsgPackRpc -> S.Method MsgPackRpc
        convertMethod l@(Listener f) =
            S.method (getMethodName l) $
            \r -> S.ServerT $ do
                fork_ $ f r
                return ()

    close = undefined

-- * Instances

type instance ThreadId MsgPackRpc = C.ThreadId

instance MonadBaseControl IO MsgPackRpc where
    type StM MsgPackRpc a = a

    liftBaseWith f = MsgPackRpc $ liftBaseWith $ \g -> f $ g . unwrapMsgPackRpc

    restoreM = MsgPackRpc . restoreM
