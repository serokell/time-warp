{-# LANGUAGE IncoherentInstances #-}
{-# LANGUAGE Rank2Types          #-}

-- | Contains benchmarks of emulation mode and networking.

module Main
    ( main
    ) where


import qualified Control.Concurrent          as C
import           Control.DeepSeq             (NFData)
import           Control.Lens                ((<&>))
import           Control.Monad               (void)
import           Control.Monad.Trans.Control (MonadBaseControl (..))
import qualified Control.TimeWarp.Rpc        as N
import           Gauge                       (Benchmark, Benchmarkable (..), bench,
                                              bgroup, defaultMain, perBatchEnvWithCleanup)

import qualified Scenarios                   as S

main :: IO ()
main = defaultMain
    [ bgroup "networking/real"
        [ bgroup "simple"
          [udpVsRpcBenchmark "" S.simple]

        , bgroup "heavyweight" $ [100, 1000] <&> \size ->
          udpVsRpcBenchmark ("size " ++ show size) (S.heavyweight size)

        , bgroup "multiple packets" $ [10000] <&> \num ->
          udpVsRpcBenchmark (show num ++ " packets") (S.repeated num)
        ]
    ]

udpVsRpcBenchmark :: String -> (forall m. S.MonadOneWay m => S.Scenario m) -> Benchmark
udpVsRpcBenchmark name scenario =
    bgroup name
    [ bench "udp" $
      perBatchEnvWithCleanupM N.runMsgPackUdp scenario
    , bench "rpc" $
      perBatchEnvWithCleanupM (N.runMsgPackRpc . N.withExtendedRpcOptions)
                              scenario
    ]

-- | Allows to benchmark action under custom monad.
--
-- It works as follows:
--
-- * Monad is run in separate thread, and waits for benchmark end before
-- existing monad. This allows to work even if monad performs cleanup action
-- upon exit.
--
-- * While main action is blocked under monad, 'StM' environment is taken
-- and benchmarked action is run with it under benchmarking thread.
perBatchEnvWithCleanupM
    :: (MonadBaseControl IO m, NFData (StM m ()))
    => (m () -> IO ()) -> S.Scenario m -> Benchmarkable
perBatchEnvWithCleanupM runM S.Scenario{..} =
    perBatchEnvWithCleanup initial cleanup action
  where
    initial _runs = do
        envBox <- C.newEmptyMVar
        lock <- C.newEmptyMVar
        void . C.forkIO $ do
            runM $ do
                env <- scenarioInit
                liftBaseWith $ \runInIO -> do
                    C.putMVar envBox (runInIO, env)
                    C.takeMVar lock
        allEnv <- C.takeMVar envBox
        return (lock, allEnv)
    cleanup _runs (lock, (runInIO, env)) = do
        _ <- runInIO $ scenarioCleanup env
        C.putMVar lock ()
    action (_, (runInIO, env)) =
        void $ runInIO (scenarioAction env)

-- withExpSamples :: (Num a, Ord a) => a -> a -> (a -> b) -> [b]
-- withExpSamples a n f =
--     let samples = takeWhile (<= n) $ iterate (* a) 1
--     in  map f samples

