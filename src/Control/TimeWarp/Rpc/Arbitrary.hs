-- | Arbitrary instances for TimeWarp.Rpc types.

module Control.TimeWarp.Rpc.Arbitrary
       (
       ) where

import           Control.TimeWarp.Rpc.PureRpc (ConnectionOutcome (ConnectedIn))
import           System.Random                (StdGen, mkStdGen)
import           Test.QuickCheck              (Arbitrary (arbitrary))

import qualified Control.TimeWarp.Rpc.PureRpc as PureRpc

instance Arbitrary StdGen where
    arbitrary = mkStdGen <$> arbitrary

instance Arbitrary PureRpc.Delays where
    arbitrary =
        pure $
        PureRpc.Delays
            (\_ -> ConnectedIn <$> PureRpc.getRandomTR (0, 1000))
