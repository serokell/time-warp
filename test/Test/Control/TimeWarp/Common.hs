-- | Common code.

module Test.Control.TimeWarp.Common
       (
       ) where

import           Control.TimeWarp.Logging (WithNamedLogger (getLoggerName))

instance WithNamedLogger IO where
    getLoggerName = pure "TimeWarp tests"
