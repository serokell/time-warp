{-# LANGUAGE DeriveDataTypeable   #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Control.TimeWarp.Logging
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- Logging functionality. This module is wrapper over
-- <http://hackage.haskell.org/package/hslogger hslogger>,
-- which allows to keep logger name in monadic context.
-- Messages are colored depending on used serverity.

module Control.TimeWarp.Logging
       ( Severity (..)
       , initLogging
       , initLoggerByName

       , LoggerName (..)

         -- * Remove boilerplate
       , WithNamedLogger (..)
       , setLoggerName
       , LoggerNameBox (..)
       , usingLoggerName

         -- * Logging functions
       , logDebug
       , logError
       , logInfo
       , logWarning
       , logMessage
       ) where

import           Control.Monad.Base          (MonadBase)
import           Control.Monad.Catch         (MonadCatch, MonadMask, MonadThrow)
import           Control.Monad.Except        (ExceptT (..), runExceptT)
import           Control.Monad.Reader        (MonadReader (..), ReaderT, runReaderT)
import           Control.Monad.State         (MonadState (get), StateT, evalStateT)
import           Control.Monad.Trans         (MonadIO (liftIO), MonadTrans, lift)
import           Control.Monad.Trans.Cont    (ContT, mapContT)
import           Control.Monad.Trans.Control (MonadBaseControl (..))

import           Data.String                 (IsString)
import qualified Data.Text                   as T
import           Data.Text.Buildable         (Buildable)
import           Data.Typeable               (Typeable)
import           GHC.Generics                (Generic)

import           System.Console.ANSI         (Color (Blue, Green, Red, Yellow),
                                              ColorIntensity (Vivid),
                                              ConsoleLayer (Foreground),
                                              SGR (Reset, SetColor), setSGRCode)
import           System.IO                   (stderr, stdout)
import           System.Log.Formatter        (simpleLogFormatter)
import           System.Log.Handler          (setFormatter)
import           System.Log.Handler.Simple   (streamHandler)
import           System.Log.Logger           (Priority (DEBUG, ERROR, INFO, WARNING),
                                              logM, removeHandler, rootLoggerName,
                                              setHandlers, setLevel, updateGlobalLogger)

-- | This type is intended to be used as command line option
-- which specifies which messages to print.
data Severity
    = Debug
    | Info
    | Warning
    | Error
    deriving (Generic, Typeable, Show, Read, Eq)

-- | Logger name to keep in context.
newtype LoggerName = LoggerName
    { loggerName :: String
    } deriving (Show, IsString, Buildable)

-- | Defined such that @n1@ is parent for @(n1 <> n2)@
-- (see <http://hackage.haskell.org/package/hslogger-1.2.10/docs/System-Log-Logger.html hslogger description>).
instance Monoid LoggerName where
    mempty = ""

    LoggerName base `mappend` LoggerName suffix
        | null base = LoggerName suffix
        | null suffix = LoggerName base
        | otherwise = LoggerName $ base ++ "." ++ suffix

convertSeverity :: Severity -> Priority
convertSeverity Debug   = DEBUG
convertSeverity Info    = INFO
convertSeverity Warning = WARNING
convertSeverity Error   = ERROR

-- | Initiates specified loggers, and sets severity of root logger's handler to
-- `Debug`
initLogging :: [LoggerName] -> Severity -> IO ()
initLogging predefinedLoggers sev = do
    updateGlobalLogger rootLoggerName removeHandler
    updateGlobalLogger rootLoggerName $ setLevel DEBUG
    mapM_ (initLoggerByName sev) predefinedLoggers

-- | Turns logger with specified name on.
-- All messages are printed to /stdout/, moreover messages with at least
-- `Error` severity are printed to /stderr/.
initLoggerByName :: Severity -> LoggerName -> IO ()
initLoggerByName (convertSeverity -> s) LoggerName{..} = do
    stdoutHandler <-
        (flip setFormatter) stdoutFormatter <$> streamHandler stdout s
    stderrHandler <-
        (flip setFormatter) stderrFormatter <$> streamHandler stderr ERROR
    updateGlobalLogger loggerName $ setHandlers [stdoutHandler, stderrHandler]
  where
    stderrFormatter = simpleLogFormatter
        ("[$time] " ++ colorizer ERROR "[$loggername:$prio]: " ++ "$msg")
    stdoutFormatter h r@(pr, _) n =
        simpleLogFormatter (colorizer pr "[$loggername:$prio] " ++ "$msg") h r n

-- | Defines pre- and post-printed characters for printing colorized text.
table :: Priority -> (String, String)
table priority = case priority of
    ERROR   -> (setColor Red   , reset)
    DEBUG   -> (setColor Green , reset)
    WARNING -> (setColor Yellow, reset)
    INFO    -> (setColor Blue  , reset)
    _       -> ("", "")
  where
    setColor color = setSGRCode [SetColor Foreground Vivid color]
    reset = setSGRCode [Reset]

-- | Colorizes text.
colorizer :: Priority -> String -> String
colorizer pr s = before ++ s ++ after
  where
    (before, after) = table pr

-- | This type class exists to remove boilerplate logging
-- by adding the logger's name to the context in each module.
class WithNamedLogger m where
    -- | Extract logger name from context
    getLoggerName :: m LoggerName

    -- | Change logger name in context
    modifyLoggerName :: (LoggerName -> LoggerName) -> m a -> m a

-- | Set logger name in context.
setLoggerName :: WithNamedLogger m => LoggerName -> m a -> m a
setLoggerName = modifyLoggerName . const

instance (Monad m, WithNamedLogger m) =>
         WithNamedLogger (ReaderT a m) where
    getLoggerName = lift getLoggerName

    modifyLoggerName how m =
        ask >>= lift . modifyLoggerName how . runReaderT m

instance (Monad m, WithNamedLogger m) =>
         WithNamedLogger (StateT a m) where
    getLoggerName = lift getLoggerName

    modifyLoggerName how m =
        get >>= lift . modifyLoggerName how . evalStateT m

instance (Monad m, WithNamedLogger m) =>
         WithNamedLogger (ExceptT e m) where
    getLoggerName = lift getLoggerName

    modifyLoggerName how = ExceptT . modifyLoggerName how . runExceptT

instance (Monad m, WithNamedLogger m) =>
         WithNamedLogger (ContT r m) where
    getLoggerName = lift getLoggerName

    modifyLoggerName = mapContT . modifyLoggerName


-- | Default implementation of `WithNamedLogger`.
newtype LoggerNameBox m a = LoggerNameBox
    { loggerNameBoxEntry :: ReaderT LoggerName m a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadTrans,
                MonadThrow, MonadCatch, MonadMask, MonadState s, MonadBase __)


instance MonadReader r m => MonadReader r (LoggerNameBox m) where
    ask = lift ask
    reader = lift . reader
    local f (LoggerNameBox m) = getLoggerName >>= lift . local f . runReaderT m

-- | Runs a `LoggerNameBox` with specified initial `LoggerName`.
usingLoggerName :: LoggerName -> LoggerNameBox m a -> m a
usingLoggerName name = flip runReaderT name . loggerNameBoxEntry

instance MonadBaseControl b m => MonadBaseControl b (LoggerNameBox m) where
    type StM (LoggerNameBox m) a = StM m a
    liftBaseWith f =
        LoggerNameBox $ liftBaseWith $ \runInBase -> f (runInBase . loggerNameBoxEntry)
    restoreM = LoggerNameBox . restoreM

instance Monad m =>
         WithNamedLogger (LoggerNameBox m) where
    getLoggerName = LoggerNameBox ask

    modifyLoggerName how = LoggerNameBox . local how . loggerNameBoxEntry

-- | Shortcut for `logMessage` to use according severity.
logDebug, logInfo, logWarning, logError
    :: (WithNamedLogger m, MonadIO m)
    => T.Text -> m ()
logDebug   = logMessage Debug
logInfo    = logMessage Info
logWarning = logMessage Warning
logError   = logMessage Error

-- | Logs message with specified severity using logger name in context.
logMessage
    :: (WithNamedLogger m, MonadIO m)
    => Severity -> T.Text -> m ()
logMessage severity t = do
    LoggerName{..} <- getLoggerName
    liftIO . logM loggerName (convertSeverity severity) $ T.unpack t
