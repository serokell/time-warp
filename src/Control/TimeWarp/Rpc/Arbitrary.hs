-- | Arbitrary instances for TimeWarp.Rpc types.

module Control.TimeWarp.Rpc.Arbitrary
       (
       ) where

import           System.Random                (StdGen, mkStdGen)
import           Test.QuickCheck              (Arbitrary (arbitrary))

instance Arbitrary StdGen where
    arbitrary = mkStdGen <$> arbitrary
