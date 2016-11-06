-- |
-- Module      : Control.TimeWarp.Logging.Formatter
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module contains pretty looking formatters for logger.

module Control.TimeWarp.Logging.Formatter
       ( setStderrFormatter
       , setStdoutFormatter
       ) where

import           Data.Monoid                    (mconcat)
import           Data.String                    (IsString)

import           System.Log.Formatter           (LogFormatter, simpleLogFormatter)
import           System.Log.Handler             (LogHandler (setFormatter))
import           System.Log.Logger              (Priority (ERROR))

import           Control.TimeWarp.Logging.Color (colorizer)

timeFmt :: IsString s => s
timeFmt = "[$time] "

timeFmtStdout :: IsString s => Bool -> s
timeFmtStdout isShowTime = if isShowTime
                           then timeFmt
                           else ""

stderrFormatter :: LogFormatter a
stderrFormatter =
    simpleLogFormatter $
        mconcat [colorizer ERROR "[$loggername:$prio] ", timeFmt, "$msg"]

stdoutFmt :: Priority -> Bool -> String
stdoutFmt pr isShowTime = mconcat
    [colorizer pr "[$loggername:$prio] ", timeFmtStdout isShowTime, "$msg"]

stdoutFormatter :: Bool -> LogFormatter a
stdoutFormatter isShowTime handle r@(pr, _) =
    simpleLogFormatter (stdoutFmt pr isShowTime) handle r

setStdoutFormatter :: LogHandler h => Bool -> h -> h
setStdoutFormatter isShowTime = (`setFormatter` stdoutFormatter isShowTime)

setStderrFormatter :: LogHandler h => h -> h
setStderrFormatter = (`setFormatter` stderrFormatter)
