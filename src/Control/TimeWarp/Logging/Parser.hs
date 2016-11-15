{-# LANGUAGE CPP #-}

-- |
-- Module      : Control.TimeWarp.Logging.Parser
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- Parser for configuring and initializing logger from YAML file.
-- Logger configuration should look like this:
--
-- > node:                    # logger named «node»
-- >     severity: Warning    # severity for logger «node»
-- >     comm:                # logger named «node.comm»
-- >         severity: Info   # severity for logger «node.comm»
-- >         file: patak.jpg  # messages will be also printed to patak.jpg
--
-- And this configuration corresponds two loggers with 'LoggerName'`s
-- @node@ and @node.comm@.

module Control.TimeWarp.Logging.Parser
       ( initLoggingFromYaml
       , initLoggingFromYamlWithMapper
       , parseLoggerConfig
       , traverseLoggerConfig
       ) where

#if PatakDebugSkovorodaBARDAQ
import qualified Data.ByteString.Char8                 as BS (putStrLn)
import           Data.Yaml.Pretty                      (defConfig, encodePretty)
#endif

import           Control.Error.Util                    ((?:))
import           Control.Exception                     (throwIO)
import           Control.Monad                         (join)
import           Control.Monad.Extra                   (whenJust)
import           Control.Monad.IO.Class                (MonadIO (liftIO))

import           Data.Foldable                         (for_)
import qualified Data.HashMap.Strict                   as HM hiding (HashMap)
import           Data.Monoid                           ((<>))
import           Data.Text                             (unpack)
import           Data.Yaml                             (decodeFileEither)

import           System.Log.Handler.Simple             (fileHandler)
import           System.Log.Logger                     (addHandler, updateGlobalLogger)

import           Control.TimeWarp.Logging.Formatter    (setStdoutFormatter)
import           Control.TimeWarp.Logging.LoggerConfig (LoggerConfig (..))
import           Control.TimeWarp.Logging.Wrapper      (LoggerName (..),
                                                        Severity (Debug, Warning),
                                                        convertSeverity, initLogging,
                                                        setSeverityMaybe)

traverseLoggerConfig
    :: MonadIO m
    => (LoggerName -> LoggerName)
    -> LoggerName
    -> LoggerConfig
    -> m ()
traverseLoggerConfig logMapper = processLoggers
  where
    processLoggers:: MonadIO m => LoggerName -> LoggerConfig -> m ()
    processLoggers parent LoggerConfig{..} = do
        setSeverityMaybe parent lcSeverity
        whenJust lcFile $ \fileName -> liftIO $ do
            let fileSeverity   = convertSeverity $ lcSeverity ?: Debug
            thisLoggerHandler <- setStdoutFormatter True <$> fileHandler fileName fileSeverity
            updateGlobalLogger (loggerName parent) $ addHandler thisLoggerHandler

        for_ (HM.toList lcSubloggers) $ \(name, loggerConfig) -> do
            let thisLoggerName = LoggerName $ unpack name
            let thisLogger     = parent <> logMapper thisLoggerName
            processLoggers thisLogger loggerConfig

-- | Parses logger config from given file path.
parseLoggerConfig :: MonadIO m => FilePath -> m LoggerConfig
parseLoggerConfig loggerConfigPath =
    liftIO $ join $ either throwIO return <$> decodeFileEither loggerConfigPath

-- | Initialize logger hierarchy from configuration file.
-- See this module description.
initLoggingFromYamlWithMapper
    :: MonadIO m
    => (LoggerName -> LoggerName)
    -> FilePath
    -> m ()
initLoggingFromYamlWithMapper loggerMapper loggerConfigPath = do
    loggerConfig <- parseLoggerConfig loggerConfigPath

#if PatakDebugSkovorodaBARDAQ
    liftIO $ BS.putStrLn $ encodePretty defConfig loggerConfig
#endif

    initLogging Warning
    traverseLoggerConfig loggerMapper mempty loggerConfig

initLoggingFromYaml :: MonadIO m => FilePath -> m ()
initLoggingFromYaml = initLoggingFromYamlWithMapper id
