-- | Common code.

module Test.Control.TimeWarp.Common
       (
       ) where

import           Data.Time.Units                   (TimeUnit, convertUnit,
                                                    fromMicroseconds)
import           System.Random                     (StdGen, mkStdGen)
import           System.Wlog                       (WithNamedLogger (..))
import           Test.QuickCheck                   (Arbitrary (arbitrary), choose)

import qualified Control.TimeWarp.Timed.MonadTimed as T


instance WithNamedLogger IO where
    getLoggerName = pure "TimeWarp tests"

    modifyLoggerName = const id


-- * Usefull arbitraries

convertMicroSecond :: TimeUnit t => T.Microsecond -> t
convertMicroSecond = convertUnit

instance Arbitrary T.Microsecond where
    -- no more than 10 minutes
    arbitrary = fromMicroseconds <$> choose (0, 600 * 1000 * 1000)

instance Arbitrary T.Millisecond where
    arbitrary = convertMicroSecond <$> arbitrary

instance Arbitrary T.Second where
    arbitrary = convertMicroSecond <$> arbitrary

instance Arbitrary T.Minute where
    arbitrary = convertMicroSecond <$> arbitrary

instance Arbitrary StdGen where
    arbitrary = mkStdGen <$> arbitrary
