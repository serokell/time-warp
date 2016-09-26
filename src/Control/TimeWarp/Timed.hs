-- | This module provides time- and thread-management capabilities.
-- It allows to write scenarios over multithreaded systems, which can
-- then be launched as either real program or emulation with no need
-- to wait for delays.
--
-- Example:
--
-- @
-- example :: MonadTimed m => m ()
-- example = do
--     schedule (at 10 minute) $ do
--         time <- toMicroseconds \<\$\> localTime
--         liftIO $ putStrLn $ \"Hello! It's \" ++ show time ++ " now"
--     wait (for 9 minute)
--     liftIO $ putStrLn \"One more minute...\"
-- @
--
-- Such scenario can be launched in real mode using
--
-- >>> runTimedIO example
-- <9 minutes passed>
-- One more minute...
-- <1 more minute passed>
-- Hello! It's 600000000µs now
--
-- and like emulation via
--
-- >>> runTimedT example
-- One more minute...
-- Hello! It's 600000000µs now
--
-- which works on the spot.

module Control.TimeWarp.Timed
       ( module Control.TimeWarp.Timed.MonadTimed
       , module Control.TimeWarp.Timed.TimedIO
       , module Control.TimeWarp.Timed.TimedT
       , module Control.TimeWarp.Timed.Misc
       ) where

import           Control.TimeWarp.Timed.Misc
import           Control.TimeWarp.Timed.MonadTimed
import           Control.TimeWarp.Timed.TimedIO
import           Control.TimeWarp.Timed.TimedT
