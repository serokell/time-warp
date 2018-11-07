{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs     #-}

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
       ( rpcCap
       ) where

import Control.Monad.Catch (Handler (..), MonadCatch, MonadThrow (..), catches, handleAll)
import Control.Monad.Trans (MonadIO (..))
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.Conduit.Serialization.Binary (ParseError)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf)
import Data.MessagePack.Object (fromObject, toObject)
import qualified Data.Text as T
import qualified Data.Text.Encoding as Encoding
import Formatting (sformat, shown, (%))
import GHC.IO.Exception (IOException (IOError), ioe_errno)
import Monad.Capabilities (CapImpl (..), CapsT)
import qualified Network.MessagePack.Client as C
import qualified Network.MessagePack.Server as S

import Control.TimeWarp.Rpc.MonadRpc (MessageId (..), Method (..), MethodTry (..), Mode (..),
                                      NetworkAddress, Port, Rpc (..), RpcError (..),
                                      RpcRequest (..), methodMessageId, mkMethodTry, proxyOf)
import Control.TimeWarp.Timed (Timed)

-- Data which server sends to client.
-- message about unexpected error | (expected error | result)
type ResponseData r = Either T.Text (Either (ExpectedError r) (Response r))

realCall :: forall r m. (MonadIO m, RpcRequest r) => NetworkAddress -> r -> m (Response r)
realCall (addr, port) req = liftIO $ do
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

    unwrapResponseData :: (MonadThrow n, RpcRequest r)
                        => r -> ResponseData r -> n (Response r)
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

    rpcErrorH :: MonadThrow n => C.RpcError -> n a
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
    noSuchMethodH :: MonadThrow n => ParseError -> n a
    noSuchMethodH _ = throwM $ NetworkProblem noSuchMethod

    noSuchMethod = sformat ("No method " % shown % " found at port " % shown)
                          msgId port

realServe
    :: forall m caps. (MonadIO m, MonadCatch m, MonadBaseControl IO m)
    => Port -> [Method 'RemoteCall (CapsT caps m)] -> CapsT caps m ()
realServe port methods = S.serve port $ convertMethod <$> methods
    where
      convertMethod :: Method 'RemoteCall (CapsT caps m) -> S.Method (CapsT caps m)
      convertMethod m =
          case mkMethodTry m of
              MethodTry f -> S.method (messageIdToName $ methodMessageId m) $
                  S.ServerT . fmap toObject . handleAny . fmap Right . f

      handleAny = handleAll $ return . Left .
                  sformat ("Got unexpected exception in server's method: " % shown)


-- | Rpc via <https://hackage.haskell.org/package/msgpack-rpc-1.0.0 msgpack-rpc>.
rpcCap :: CapImpl Rpc '[Timed] IO
rpcCap = CapImpl Rpc
    { _call = realCall
    , _serve = realServe
    }

messageIdToName :: MessageId -> String
messageIdToName (MessageId name) = [toEnum name]
