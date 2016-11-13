-- |
-- Module      : Control.TimeWarp.Logging.LoggerConfig
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- Logger configuration.

module Control.TimeWarp.Logging.LoggerConfig
       ( LoggerConfig (..)
       , LoggerMap
       , commLoggerName
       , commLoggerTag
       ) where

import           Data.Aeson                       (withObject)
import           Data.HashMap.Strict              (HashMap)
import qualified Data.HashMap.Strict              as HM hiding (HashMap)
import           Data.Text                        (Text)
import           Data.Traversable                 (for)
import           Data.Yaml                        (FromJSON (..), ToJSON, (.:?))
import           GHC.Generics                     (Generic)

import           Control.TimeWarp.Logging.Wrapper (Severity)

type LoggerMap = HashMap Text LoggerConfig

data LoggerConfig = LoggerConfig
    { lcSubloggers :: LoggerMap
    , lcFile       :: Maybe FilePath
    , lcSeverity   :: Maybe Severity
    } deriving (Generic, Show)

instance ToJSON LoggerConfig

nonLoggers :: [Text]
nonLoggers = ["file", "severity"]

selectLoggers :: HashMap Text a -> HashMap Text a
selectLoggers = HM.filterWithKey $ \k _ -> k `notElem` nonLoggers

instance FromJSON LoggerConfig where
    parseJSON = withObject "root loggers" $ \o -> do
        lcFile       <- o .:? "file"
        lcSeverity   <- o .:? "severity"
        lcSubloggers <- for (selectLoggers o) parseJSON
        return LoggerConfig{..}

-- | Tag for 'LoggerName'. Will be mapped to 'commLoggerName' if met in config.
commLoggerTag :: Text
commLoggerTag = "comm"

-- | 'LoggerName' for communication logger. It equals to 'commLoggerTag' now
-- but in future this may change.
commLoggerName :: Text
commLoggerName = "comm"
