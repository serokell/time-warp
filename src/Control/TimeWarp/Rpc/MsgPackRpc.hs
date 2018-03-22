{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}

{-# LANGUAGE DataKinds             #-}
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
import           Control.Monad.Catch               (Handler (..), MonadCatch, MonadMask,
                                                    MonadThrow (..), catches, handleAll)
import           Control.Monad.Trans               (MonadIO (..))
import           Control.Monad.Trans.Control       (MonadBaseControl, StM, liftBaseWith,
                                                    restoreM)
import           Data.IORef                        (newIORef, readIORef, writeIORef)
import           Data.List                         (isPrefixOf)
import qualified Data.Text                         as T
import qualified Data.Text.Encoding                as Encoding
import           Formatting                        (sformat, shown, (%))
import           GHC.IO.Exception                  (IOException (IOError), ioe_errno)

import           Data.Conduit.Serialization.Binary (ParseError)
import           Data.MessagePack.Object           (fromObject, toObject)
import qualified Network.MessagePack.Client        as C
import qualified Network.MessagePack.Server        as S

import           Control.TimeWarp.Rpc.MonadRpc     (MessageId (..), Method (..),
                                                    MethodTry (..), MonadRpc (..),
                                                    RpcConstraints (..), RpcError (..),
                                                    RpcOptionMessagePack, RpcRequest (..),
                                                    methodMessageId, mkMethodTry, proxyOf)
import           Control.TimeWarp.Timed            (MonadTimed (..), ThreadId, TimedIO,
                                                    runTimedIO)

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
type ResponseData r = Either T.Text (Either (ExpectedError r) (Response r))

type LocalOptions = '[RpcOptionMessagePack]

instance MonadRpc LocalOptions MsgPackRpc where
    send (addr, port) req = liftIO $ do
        box <- newIORef Nothing
        handleExc $ C.execClient (Encoding.encodeUtf8 addr) port $ do
            res <- C.call msgId req
            liftIO . writeIORef box $ Just res
        maybeRes <- readIORef box
        (unwrapResponseData req =<<) $
            maybe
                (throwM $ InternalError "execClient didn't return a value")
                return
                maybeRes
      where
        msgId = messageIdToName . messageId $ proxyOf req

        unwrapResponseData :: (MonadThrow m, RpcRequest r, RpcConstraints LocalOptions r)
                           => r -> ResponseData r -> m (Response r)
        unwrapResponseData _ (Left msg)        = throwM $ InternalError msg
        unwrapResponseData _ (Right (Left e))  = throwM $ ServerError e
        unwrapResponseData _ (Right (Right r)) = return r

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
                            then throwM $ NetworkProblem noSuchMethod
                            else throwM $ InternalError $ T.pack err

        -- when server has no needed method, somehow it ends with `ParseException`,
        -- not `C.ServerError`
        noSuchMethodH :: MonadThrow m => ParseError -> m a
        noSuchMethodH _ = throwM $ NetworkProblem noSuchMethod

        noSuchMethod = sformat ("No method " % shown % " found at port " % shown)
                              msgId port

    serve port methods = S.serve port $ convertMethod <$> methods
      where
        convertMethod :: Method LocalOptions MsgPackRpc -> S.Method MsgPackRpc
        convertMethod m =
            case mkMethodTry m of
                MethodTry f -> S.method (messageIdToName $ methodMessageId m) $
                    S.ServerT . fmap toObject . handleAny . fmap Right . f

        handleAny = handleAll $ return . Left .
                    sformat ("Got unexpected exception in server's method: " % shown)

messageIdToName :: MessageId -> String
messageIdToName (MessageId name) = [toEnum name]

-- * Instances

type instance ThreadId MsgPackRpc = C.ThreadId

instance MonadBaseControl IO MsgPackRpc where
    type StM MsgPackRpc a = a

    liftBaseWith f = MsgPackRpc $ liftBaseWith $ \g -> f $ g . unwrapMsgPackRpc

    restoreM = MsgPackRpc . restoreM
