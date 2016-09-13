-- | Common code.

module Test.Control.TimeWarp.Common
       (
       ) where

import           Control.TimeWarp.Logging (WithNamedLogger (..))

instance WithNamedLogger IO where
    getLoggerName = pure "TimeWarp tests"

    modifyLoggerName = const id
