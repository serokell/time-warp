{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE Rank2Types           #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Control.TimeWarp.Rpc.MsgPackUdp
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- Implements 'MonadRpc' via UDP protocol.

module Control.TimeWarp.Rpc.MsgPackUdp
    ( MsgPackUdp (..)
    , runMsgPackUdp
    ) where

import           Control.Lens                  ((<&>))
import           Control.Monad                 (forever, when)
import           Control.Monad.Base            (MonadBase)
import           Control.Monad.Catch           (Exception, MonadCatch, MonadMask,
                                                MonadThrow, bracket, onException, throwM)
import           Control.Monad.Reader          (ReaderT (..))
import           Control.Monad.Trans           (MonadIO (..))
import           Control.Monad.Trans.Control   (MonadBaseControl (..))
import           Control.TimeWarp.Rpc.MonadRpc (Method (..), MonadRpc (..),
                                                NetworkAddress, RpcOptionMessagePack,
                                                RpcOptionNoReturn, messageId,
                                                methodMessageId)
import           Control.TimeWarp.Timed        (MonadTimed, ThreadId, TimedIO, runTimedIO)
import qualified Data.Binary                   as Binary
import qualified Data.ByteString.Lazy          as LBS
import qualified Data.Map                      as M
import           Data.Maybe                    (fromMaybe)
import qualified Data.MessagePack              as MsgPack
import           Data.Proxy                    (Proxy (..))
import qualified Data.Text                     as T
import           Formatting                    (sformat, shown, (%))
import qualified Network.Socket                as N hiding (recv, sendTo)
import qualified Network.Socket.ByteString     as N
import           Text.Read                     (readMaybe)

type LocalOptions = '[RpcOptionMessagePack, RpcOptionNoReturn]

withUdpSocket :: (MonadIO m, MonadMask m) => (N.Socket -> m a) -> m a
withUdpSocket = bracket mkSocket close
  where
    mkSocket = liftIO $ N.socket N.AF_INET N.Datagram N.defaultProtocol
    close = liftIO . N.close

newtype MsgPackUdp a = MsgPackUdp
    { unwrapMsgPackRpc :: ReaderT N.Socket TimedIO a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadBase IO,
                MonadThrow, MonadCatch, MonadMask, MonadTimed)

runMsgPackUdp :: MsgPackUdp a -> IO a
runMsgPackUdp (MsgPackUdp action) = do
    withUdpSocket $ \sock ->
        runTimedIO $ runReaderT action sock

type instance ThreadId MsgPackUdp = ThreadId TimedIO

instance MonadBaseControl IO MsgPackUdp where
    type StM MsgPackUdp a = StM (ReaderT N.Socket TimedIO) a
    liftBaseWith f =
        MsgPackUdp $ liftBaseWith $ \runInIO ->
            f $ runInIO . unwrapMsgPackRpc
    restoreM = MsgPackUdp . restoreM

newtype PacketSizeOverflow = PacketSizeOverflow Integer
    deriving (Eq, Show)

instance Exception PacketSizeOverflow

newtype DecodeException = DecodeException T.Text
    deriving (Eq, Show)

instance Exception DecodeException

instance MonadRpc LocalOptions MsgPackUdp where
    send addr (msg :: msg) = MsgPackUdp . ReaderT $ \sock -> do
        let msgName = messageId @msg Proxy
            rawMsg = (msgName, msg)
            dat = Binary.encode $ MsgPack.toObject rawMsg

        let msgSize = fromIntegral $ LBS.length dat
        when (msgSize > fromIntegral maxMsgSize) $
            throwM $ PacketSizeOverflow msgSize

        liftIO $ N.sendManyTo sock (LBS.toChunks dat) (networkAddrToSockAddr addr)

    serve (fromIntegral -> port) methods = do
        -- one socket per listener
        withUdpSocket $ \sock -> do
            liftIO $ N.bind sock (N.SockAddrInet port N.iNADDR_ANY) `onException` putStrLn "bind failed"
            forever $ receive sock
      where
        methodsMap = M.fromList $ methods <&> \m -> (methodMessageId m, m)
        receive :: N.Socket -> MsgPackUdp ()
        receive sock = do
            dat <- liftIO $ N.recv sock maxMsgSize

            either (throwM . DecodeException) id $ do
                obj <- case Binary.decodeOrFail (LBS.fromStrict dat) of
                    Left _            -> Left "failed to decode to MessagePack"
                    Right (_, _, obj) -> Right obj

                (msgId, msgObj :: MsgPack.Object)
                    <- maybe (Left "failed to get message id") Right $
                       MsgPack.fromObject obj

                Method f <-
                    maybe (Left $ sformat ("No method " % shown % " found") msgId) Right $
                    M.lookup msgId methodsMap

                action <-
                    maybe (Left "failed to decode from MessagePack") (Right . f) $
                    MsgPack.fromObject msgObj

                return action

maxMsgSize :: Int
maxMsgSize = 1500

networkAddrToSockAddr :: NetworkAddress -> N.SockAddr
networkAddrToSockAddr (ip, port) =
    let ip' =
          case map parse (split ip) of
            [a1, a2, a3, a4] -> N.tupleToHostAddress (a1, a2, a3, a4)
            _                -> incorrectIp
    in  N.SockAddrInet (fromIntegral port) ip'
  where
    incorrectIp = error "send: incorrect api"
    split = T.splitOn "."
    parse = fromMaybe incorrectIp . readMaybe . T.unpack
