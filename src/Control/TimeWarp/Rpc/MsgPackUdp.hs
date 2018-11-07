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
    ( udpCap
    ) where

import Control.Monad (forever, when)
import Control.Monad.Base (MonadBase)
import Control.Monad.Catch (Exception, MonadMask, MonadThrow, bracket, throwM)
import Control.Monad.Trans (MonadIO (..))
import qualified Data.Binary as Binary
import qualified Data.ByteString.Lazy as LBS
import Data.Default (Default (..))
import qualified Data.HashMap.Strict as HM
import qualified Data.IORef.Lifted as Ref
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import qualified Data.MessagePack as MsgPack
import Data.Proxy (Proxy (..))
import qualified Data.Text as T
import Formatting (sformat, shown, (%))
import GHC.IO.Unsafe (unsafePerformIO)
import Monad.Capabilities (CapImpl (..), CapsT, HasCap)
import qualified Network.Socket as N hiding (recv, sendTo)
import qualified Network.Socket.ByteString as N
import Text.Read (readMaybe)

import Control.TimeWarp.Rpc.MonadRpc (Host, Method (..), Mode (..), NetworkAddress, Send (..),
                                      buildMethodsMap, messageId)
import Control.TimeWarp.Timed (Timed, fork_)

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

newtype PacketSizeOverflow = PacketSizeOverflow Integer
    deriving (Eq, Show)

instance Exception PacketSizeOverflow

newtype DecodeException = DecodeException T.Text
    deriving (Eq, Show)

instance Exception DecodeException

udpCap :: (MonadIO m, MonadMask m) => MsgPackUdpOptions -> m (CapImpl Send '[Timed] IO)
udpCap MsgPackUdpOptions{..} =
    withUdpSocket $ \globalSock ->
    return $ CapImpl $ Send
        { _send = \addr (msg :: msg) -> do
            let msgName = messageId @msg Proxy
                rawMsg = (msgName, msg)
                dat = Binary.encode $ MsgPack.toObject rawMsg

            let msgSize = fromIntegral $ LBS.length dat
            when (msgSize > fromIntegral udpMessageSizeLimit) $
                throwM $ PacketSizeOverflow msgSize

            sockAddr <- networkAddrToSockAddr udpCacheAddresses addr
            liftIO $ N.sendManyTo globalSock (LBS.toChunks dat) sockAddr

        , _listen = \(fromIntegral -> port) methods -> do
            -- one socket per listener
            withUdpSocket $ \sock -> do
                liftIO $ N.bind sock (N.SockAddrInet port N.iNADDR_ANY)
                forever $ receive methods sock
        }
  where
    methodsMap methods = either (error . T.unpack) id $ buildMethodsMap methods
    receive :: (MonadIO m, MonadThrow m, HasCap Timed caps)
            => [Method 'OneWay (CapsT caps m)] -> N.Socket -> CapsT caps m ()
    receive methods sock = do
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
                M.lookup msgId $ methodsMap methods

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
