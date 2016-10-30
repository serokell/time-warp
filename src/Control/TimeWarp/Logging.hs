{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}

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
       , initLoggingWith
       , setSeverity
       , setSeverityMaybe

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

import           Control.Lens                (Wrapped (..), iso)
import           Control.Monad.Base          (MonadBase)
import           Control.Monad.Catch         (MonadCatch, MonadMask, MonadThrow)
import           Control.Monad.Except        (ExceptT (..), runExceptT)
import           Control.Monad.Reader        (MonadReader (..), ReaderT, runReaderT)
import           Control.Monad.State         (MonadState (get), StateT, evalStateT)
import           Control.Monad.Trans         (MonadIO (liftIO), MonadTrans, lift)
import           Control.Monad.Trans.Cont    (ContT, mapContT)
import           Control.Monad.Trans.Control (MonadBaseControl (..))

import           Data.Default                (Default (def))
import           Data.Semigroup              (Semigroup)
import qualified Data.Semigroup              as Semigroup
import           Data.String                 (IsString)
import qualified Data.Text                   as T
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
                                              clearLevel, logM, rootLoggerName,
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
    } deriving (Show, IsString)

instance Monoid LoggerName where
    mempty = ""
    mappend = (Semigroup.<>)

-- | Defined such that @n1@ is parent for @(n1 <> n2)@
-- (see <http://hackage.haskell.org/package/hslogger-1.2.10/docs/System-Log-Logger.html hslogger description>).
instance Semigroup LoggerName where
    LoggerName base <> LoggerName suffix
        | null base   = LoggerName suffix
        | null suffix = LoggerName base
        | otherwise   = LoggerName $ base ++ "." ++ suffix

convertSeverity :: Severity -> Priority
convertSeverity Debug   = DEBUG
convertSeverity Info    = INFO
convertSeverity Warning = WARNING
convertSeverity Error   = ERROR

-- | Options determining formatting of messages.
data LoggingFormat = LoggingFormat
    { -- | Show time for non-error messages.
      -- Note that error messages always have timestamp.
      lfShowTime :: !Bool
    } deriving (Show)

instance Default LoggingFormat where
    def = LoggingFormat {lfShowTime = True}

-- | This function initializes global logging system. At high level, it sets
-- severity which will be used by all loggers by default, sets default
-- formatters and sets custom severity for given loggers (if any).
--
-- On a lower level it does the following:
-- 1. Removes default handler from root logger, sets two handlers such that:
-- 1.1. All messages are printed to /stdout/.
-- 1.2. Moreover messages with at least `Error` severity are
-- printed to /stderr/.
-- 2. Sets given Severity to root logger, so that it will be used by
-- descendant loggers by default.
-- 3. Applies `setSeverity` to given loggers. It can be done later using
-- `setSeverity` directly.
initLoggingWith
    :: MonadIO m
    => LoggingFormat -> Severity -> m ()
initLoggingWith LoggingFormat {..} defaultSeverity = liftIO $ do
    -- We set DEBUG here, to allow all messages by stdout handler.
    -- They will be filtered by loggers.
    stdoutHandler <-
        flip setFormatter stdoutFormatter <$> streamHandler stdout DEBUG
    stderrHandler <-
        flip setFormatter stderrFormatter <$> streamHandler stderr ERROR
    updateGlobalLogger rootLoggerName $
        setHandlers [stderrHandler, stdoutHandler]
    updateGlobalLogger rootLoggerName $
        setLevel (convertSeverity defaultSeverity)
  where
    stderrFormatter =
        simpleLogFormatter $
        mconcat [colorizer ERROR "[$loggername:$prio] ", timeFmt, "$msg"]
    timeFmt = "[$time] "
    timeFmtStdout = if lfShowTime then timeFmt else ""
    stdoutFmt pr = mconcat
        [colorizer pr "[$loggername:$prio] ", timeFmtStdout, "$msg"]
    stdoutFormatter h r@(pr, _) = simpleLogFormatter (stdoutFmt pr) h r

-- | Version of initLoggingWith without any predefined loggers.
initLogging :: MonadIO m => Severity -> m ()
initLogging = initLoggingWith def

-- | Set severity for given logger. By default parent's severity is used.
setSeverity :: MonadIO m => LoggerName -> Severity -> m ()
setSeverity (LoggerName name) =
    liftIO . updateGlobalLogger name . setLevel . convertSeverity

-- | Set or clear severity.
setSeverityMaybe
    :: MonadIO m
    => LoggerName -> Maybe Severity -> m ()
setSeverityMaybe (LoggerName name) Nothing =
    liftIO $ updateGlobalLogger name $ clearLevel
setSeverityMaybe n (Just x) = setSeverity n x

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
    } deriving (Functor, Applicative, Monad, MonadIO, MonadTrans, MonadBase b,
                MonadThrow, MonadCatch, MonadMask, MonadState s)


instance MonadReader r m => MonadReader r (LoggerNameBox m) where
    ask = lift ask
    reader = lift . reader
    local f (LoggerNameBox m) = getLoggerName >>= lift . local f . runReaderT m

instance MonadBaseControl b m => MonadBaseControl b (LoggerNameBox m) where
    type StM (LoggerNameBox m) a = StM (ReaderT LoggerName m) a
    liftBaseWith io =
        LoggerNameBox $ liftBaseWith $ \runInBase -> io $ runInBase . loggerNameBoxEntry
    restoreM = LoggerNameBox . restoreM

instance Wrapped (LoggerNameBox m a) where
    type Unwrapped (LoggerNameBox m a) = ReaderT LoggerName m a
    _Wrapped' = iso loggerNameBoxEntry LoggerNameBox

-- | Runs a `LoggerNameBox` with specified initial `LoggerName`.
usingLoggerName :: LoggerName -> LoggerNameBox m a -> m a
usingLoggerName name = flip runReaderT name . loggerNameBoxEntry

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
