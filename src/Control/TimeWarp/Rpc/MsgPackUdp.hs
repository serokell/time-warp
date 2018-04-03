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
    , MsgPackUdpOptions (..)
    , runMsgPackUdp
    , runMsgPackUdpOpts
    ) where

import           Control.Lens                  ((<&>))
import           Control.Monad                 (forever, when)
import           Control.Monad.Base            (MonadBase)
import           Control.Monad.Catch           (Exception, MonadCatch, MonadMask,
                                                MonadThrow, bracket, throwM)
import           Control.Monad.Reader          (ReaderT (..), ask)
import           Control.Monad.Trans           (MonadIO (..))
import           Control.Monad.Trans.Control   (MonadBaseControl (..))
import           Control.TimeWarp.Rpc.MonadRpc (Host, Method (..), MonadRpc (..),
                                                NetworkAddress, RpcOptionMessagePack,
                                                RpcOptionNoReturn, messageId,
                                                methodMessageId)
import           Control.TimeWarp.Timed        (MonadTimed, ThreadId, TimedIO, fork_,
                                                runTimedIO)
import qualified Data.Binary                   as Binary
import qualified Data.ByteString.Lazy          as LBS
import           Data.Default                  (Default (..))
import qualified Data.HashMap.Strict           as HM
import qualified Data.IORef.Lifted             as Ref
import qualified Data.Map                      as M
import           Data.Maybe                    (fromMaybe)
import qualified Data.MessagePack              as MsgPack
import           Data.Proxy                    (Proxy (..))
import qualified Data.Text                     as T
import           Formatting                    (sformat, shown, (%))
import           GHC.IO.Unsafe                 (unsafePerformIO)
import qualified Network.Socket                as N hiding (recv, sendTo)
import qualified Network.Socket.ByteString     as N
import           Text.Read                     (readMaybe)

type LocalOptions = '[RpcOptionMessagePack, RpcOptionNoReturn]

withUdpSocket :: (MonadIO m, MonadMask m) => (N.Socket -> m a) -> m a
withUdpSocket = bracket mkSocket close
  where
    mkSocket = liftIO $ N.socket N.AF_INET N.Datagram N.defaultProtocol
    close = liftIO . N.close

newtype CacheAddrs = CacheAddrs Bool

data MsgPackUdpOptions = MsgPackUdpOptions
    { udpCacheAddresses   :: CacheAddrs
      -- ^ Globally cache resolved addresses.
      -- This may give almost x2 speed up on small packets.
    , udpMessageSizeLimit :: Int
      -- ^ Limit on sent/received packet size.
    }

instance Default MsgPackUdpOptions where
    def =
        MsgPackUdpOptions
        { udpCacheAddresses = CacheAddrs True
        , udpMessageSizeLimit = 1500
        }

type LocalEnv = (MsgPackUdpOptions, N.Socket)

newtype MsgPackUdp a = MsgPackUdp
    { unwrapMsgPackRpc :: ReaderT LocalEnv TimedIO a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadBase IO,
                MonadThrow, MonadCatch, MonadMask, MonadTimed)

runMsgPackUdpOpts :: MsgPackUdpOptions -> MsgPackUdp a -> IO a
runMsgPackUdpOpts options (MsgPackUdp action) = do
    withUdpSocket $ \sock ->
        runTimedIO $ runReaderT action (options, sock)

runMsgPackUdp :: MsgPackUdp a -> IO a
runMsgPackUdp = runMsgPackUdpOpts def

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
    send addr (msg :: msg) = MsgPackUdp . ReaderT $
      \(MsgPackUdpOptions{..}, sock) -> do
        let msgName = messageId @msg Proxy
            rawMsg = (msgName, msg)
            dat = Binary.encode $ MsgPack.toObject rawMsg

        let msgSize = fromIntegral $ LBS.length dat
        when (msgSize > fromIntegral udpMessageSizeLimit) $
            throwM $ PacketSizeOverflow msgSize

        sockAddr <- networkAddrToSockAddr udpCacheAddresses addr
        liftIO $ N.sendManyTo sock (LBS.toChunks dat) sockAddr

    serve (fromIntegral -> port) methods = do
        -- one socket per listener
        withUdpSocket $ \sock -> do
            liftIO $ N.bind sock (N.SockAddrInet port N.iNADDR_ANY)
            forever $ receive sock
      where
        methodsMap = M.fromList $ methods <&> \m -> (methodMessageId m, m)
        receive :: N.Socket -> MsgPackUdp ()
        receive sock = do
            (MsgPackUdpOptions{..}, _) <- MsgPackUdp ask
            dat <- liftIO $ N.recv sock udpMessageSizeLimit

            fork_ . either (throwM . DecodeException) id $ do
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

addrCache :: Ref.IORef (HM.HashMap Host N.HostAddress)
addrCache = unsafePerformIO $ Ref.newIORef mempty

takeInAddrCache :: MonadBase IO m => (Host, N.HostAddress) -> m N.HostAddress
takeInAddrCache (host, candidateAddr) = do
    maddr <- HM.lookup host <$> Ref.readIORef addrCache
    case maddr of
        Nothing -> do
            Ref.atomicModifyIORef addrCache ((, ()) . HM.insert host candidateAddr)
            return candidateAddr
        Just addr -> return addr

networkAddrToSockAddr :: MonadBase IO m => CacheAddrs -> NetworkAddress -> m N.SockAddr
networkAddrToSockAddr (CacheAddrs useCaching) (ip, port) = do
    let hostAddr' =
          case map parse (split ip) of
            [a1, a2, a3, a4] -> N.tupleToHostAddress (a1, a2, a3, a4)
            _                -> incorrectIp
    hostAddr <-
        if useCaching
        then takeInAddrCache (ip, hostAddr')
        else pure hostAddr'
    return $ N.SockAddrInet (fromIntegral port) hostAddr
  where
    incorrectIp = error "send: incorrect api"
    split = T.splitOn "."
    parse = fromMaybe incorrectIp . readMaybe . T.unpack

