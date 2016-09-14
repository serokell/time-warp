-- | Arbitrary instances for WorkMode types.

module Control.TimeWarp.Rpc.Arbitrary
       (
       ) where

import           Control.Monad.Random.Class   (getRandomR)
import           Control.TimeWarp.Rpc.PureRpc (ConnectionSuccess (ConnectedIn))
import           Data.Time.Units              (fromMicroseconds)
import           System.Random                (StdGen, mkStdGen)
import           Test.QuickCheck              (Arbitrary (arbitrary))

import qualified Control.TimeWarp.Rpc.PureRpc as PureRpc

instance Arbitrary StdGen where
    arbitrary = mkStdGen <$> arbitrary

instance Arbitrary PureRpc.Delays where
    arbitrary =
        pure $
        PureRpc.Delays
            (\_ -> ConnectedIn . fromMicroseconds <$> getRandomR (0, 1000))
