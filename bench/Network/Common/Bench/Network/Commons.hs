{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric  #-}

module Bench.Network.Commons
    ( MsgId
    , Ping (..)
    , Pong (..)
    , removeFileIfExists
    , useBenchAsWorkingDirNotifier
    ) where

import           Control.Monad            (when)
import           Control.Monad.Catch      (MonadCatch, onException)
import           Control.Monad.Trans      (MonadIO (..))
import           Data.Binary              (Binary)
import           Data.Data                (Data)
import           Data.MessagePack         (MessagePack)
import           GHC.Generics             (Generic)
import           System.Directory         (doesFileExist, removeFile)

import           Control.TimeWarp.Logging (WithNamedLogger, logWarning)
import           Control.TimeWarp.Rpc     (Message)

type MsgId = Int

data Ping = Ping MsgId
    deriving (Generic, Data, Binary, MessagePack)

data Pong = Pong MsgId
    deriving (Generic, Data, Binary, MessagePack)

instance Message Ping
instance Message Pong

removeFileIfExists :: MonadIO m => FilePath -> m ()
removeFileIfExists path = liftIO $ do
    exists <- doesFileExist path
    when exists $ removeFile path

useBenchAsWorkingDirNotifier
    :: (MonadIO m, MonadCatch m , WithNamedLogger m) => m () -> m ()
useBenchAsWorkingDirNotifier = flip onException $
    logWarning "Ensure you run benchmarking with working directory = bench"
