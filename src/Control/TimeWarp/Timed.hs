-- | This module provides time- and thread-management capabilities.
-- It allows to write scenarios over multithreaded systems, which can
-- then be launched as either real program or emulation with no need
-- to wait for delays.
--
-- /Some interesting scenario here:/
--
-- @
-- example :: MonadTimed m => m ()
-- example = do
--     wait (for 10 minute)
--     liftIO $ putStrLn \"Hello\"
-- @
--
-- Such scenario can be launched via
--
-- @
-- runTimedIO example
-- @
--
-- for real mode or via
--
-- @
-- runTimedT example
-- @
--
-- for emulation, which works on the spot.
--

module Control.TimeWarp.Timed
       ( module Control.TimeWarp.Timed.MonadTimed
       , module Control.TimeWarp.Timed.TimedIO
       , module Control.TimeWarp.Timed.TimedT
       , module Control.TimeWarp.Timed.Misc
       ) where

import           Control.TimeWarp.Timed.Arbitrary  ()
import           Control.TimeWarp.Timed.Misc
import           Control.TimeWarp.Timed.MonadTimed
import           Control.TimeWarp.Timed.TimedIO
import           Control.TimeWarp.Timed.TimedT
