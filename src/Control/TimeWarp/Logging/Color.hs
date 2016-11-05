-- |
-- Module      : Control.TimeWarp.Logging.Color
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- Colorizing utilities for log messages.
-- Messages are colored depending on used serverity.

module Control.TimeWarp.Logging.Color
       ( colorizer
       ) where

import           System.Console.ANSI (Color (Blue, Green, Magenta, Red, Yellow),
                                      ColorIntensity (Vivid), ConsoleLayer (Foreground),
                                      SGR (Reset, SetColor), setSGRCode)

import           System.Log.Logger   (Priority (DEBUG, ERROR, INFO, NOTICE, WARNING))

-- | Defines pre- and post-printed characters for printing colorized text.
table :: Priority -> (String, String)
table priority = case priority of
    ERROR   -> (setColor Red     , reset)
    DEBUG   -> (setColor Green   , reset)
    NOTICE  -> (setColor Magenta , reset)
    WARNING -> (setColor Yellow  , reset)
    INFO    -> (setColor Blue    , reset)
    _       -> ("", "")
  where
    setColor color = setSGRCode [SetColor Foreground Vivid color]
    reset = setSGRCode [Reset]

-- | Colorizes text.
colorizer :: Priority -> String -> String
colorizer pr s = before ++ s ++ after
  where
    (before, after) = table pr
