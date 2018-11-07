{-# LANGUAGE Rank2Types #-}

-- |
-- Module      : Control.TimeWarp.Timed.TimedIO
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- Real-mode implementation of `MonadTimed`.
-- Each function in inplementation refers to plain `IO`.

module Control.TimeWarp.Timed.TimedIO
       ( timedIOCap
       ) where

import qualified Control.Concurrent as C
import Control.Monad.Catch (throwM)
import Control.Monad.Fix (fix)
import Control.Monad.Reader (ReaderT (..), ask, runReaderT)
import Control.Monad.Trans (MonadIO, lift, liftIO)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.Units (toMicroseconds)
import Monad.Capabilities (CapImpl (..))
import qualified System.Timeout as T

import Control.TimeWarp.Timed.MonadTimed (Microsecond, MonadTimedError (MTTimeoutError),
                                          ThreadId (..), Timed (..))

-- | Default implementation for `IO`, i.e. real mode.
-- `wait` refers to `Control.Concurrent.threadDelay`,
-- `fork` refers to `Control.Concurrent.forkIO`, and so on.
timedIOCap :: MonadIO m => m (CapImpl Timed '[] IO)
timedIOCap = do
    startTime <- liftIO curTime
    return $ CapImpl $ fix $ \timed -> Timed
        { _virtualTime = (-) <$> lift curTime <*> pure startTime
        , _currentTime = lift curTime
        , _wait = \relTime -> do
            cur <- _virtualTime timed
            liftIO $ C.threadDelay $ fromIntegral $ relTime cur - cur
        , _fork = \act -> lift . fmap RealThreadId . C.forkIO . runReaderT act =<< ask
        , _myThreadId = RealThreadId <$> lift C.myThreadId
        , _throwTo = \case
            RealThreadId tid -> lift . C.throwTo tid
            _ -> error "throwTo: real and pure 'Timed' are mixed up"
        , _timeout = \(toMicroseconds -> t) action -> do
            res <- liftIO . T.timeout (fromIntegral t) . runReaderT action =<< ask
            maybe (throwM $ MTTimeoutError "Timeout has exceeded") return res
        }

curTime :: IO Microsecond
curTime = round . ( * 1000000) <$> getPOSIXTime
