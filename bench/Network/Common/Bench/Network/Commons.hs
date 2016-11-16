{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric  #-}

module Bench.Network.Commons
    ( MsgId
    , Ping (..)
    , Pong (..)
    , removeFileIfExists
    , useBenchAsWorkingDirNotifier
    , curTimeMcs
    , logMeasure

    , MeasureEvent (..)
    , MeasureInfo (..)
    , LogMessage (..)
    , measureInfoParser
    , logMessageParser
    ) where

import           Control.Applicative      ((<|>))
import           Control.Monad            (when)
import           Control.Monad.Catch      (MonadCatch, onException)
import           Control.Monad.Trans      (MonadIO (..))
import           Data.Binary              (Binary)
import           Data.Data                (Data)
import           Data.Functor             (($>))
import           Data.MessagePack         (MessagePack)
import           Data.Monoid              ((<>))
import           Data.Text.Buildable      (Buildable, build)
import           Data.Time.Clock.POSIX    (getPOSIXTime)
import qualified Formatting               as F
import           GHC.Generics             (Generic)
import           System.Directory         (doesFileExist, removeFile)

import           Data.Attoparsec.Text     (Parser, decimal, skip, string)

import           Control.TimeWarp.Logging (WithNamedLogger, logInfo, logWarning)
import           Control.TimeWarp.Rpc     (Message)


type MsgId = Int

data Ping = Ping MsgId
    deriving (Generic, Data, Binary, MessagePack)

data Pong = Pong MsgId
    deriving (Generic, Data, Binary, MessagePack)

instance Message Ping
instance Message Pong


-- * Util

removeFileIfExists :: MonadIO m => FilePath -> m ()
removeFileIfExists path = liftIO $ do
    exists <- doesFileExist path
    when exists $ removeFile path

useBenchAsWorkingDirNotifier
    :: (MonadIO m, MonadCatch m , WithNamedLogger m) => m () -> m ()
useBenchAsWorkingDirNotifier = flip onException $
    logWarning "Ensure you run benchmarking with working directory = bench"

curTimeMcs :: MonadIO m => m Integer
curTimeMcs = liftIO $ round . ( * 1000000) <$> getPOSIXTime

logMeasure :: (MonadIO m, WithNamedLogger m) => MeasureEvent -> MsgId -> m ()
logMeasure miEvent miId = do
    miTime <- curTimeMcs
    logInfo $ F.sformat F.build $ LogMessage MeasureInfo{..}

-- * Logging & parsing

-- ** Measure event

-- | Type of event in measurement.
data MeasureEvent
    = PingSent
    | PingReceived
    | PongSent
    | PongReceived

instance Buildable MeasureEvent where
    build PingSent     = "• → "
    build PingReceived = " → •"
    build PongSent     = " ← •"
    build PongReceived = "• ← "

measureEventParser :: Parser MeasureEvent
measureEventParser = string "• → " $> PingSent
                 <|> string " → •" $> PingReceived
                 <|> string " ← •" $> PongSent
                 <|> string "• ← " $> PongReceived


-- ** Measure info

-- | Single event in measurement.
data MeasureInfo = MeasureInfo
    { miId    :: MsgId
    , miEvent :: MeasureEvent
    , miTime  :: Integer
    }

instance Buildable MeasureInfo where
    build MeasureInfo{..} = mconcat
        [ build miId
        , ", "
        , build miEvent
        , ", "
        , build miTime
        ]

measureInfoParser :: Parser MeasureInfo
measureInfoParser = do
    miId <- decimal
    _ <- string ", "
    miEvent <- measureEventParser
    _ <- string ", "
    miTime <- decimal
    return MeasureInfo{..}


-- ** Log message

-- | Allows to extract bare message content from logs.
-- Just inserts separator at beginning.
data LogMessage a = LogMessage a

instance Buildable a => Buildable (LogMessage a) where
    build (LogMessage a) = "#" <> build a

logMessageParser :: Parser a -> Parser (LogMessage a)
logMessageParser p = do
    skip (/= '#')
    LogMessage <$> p
