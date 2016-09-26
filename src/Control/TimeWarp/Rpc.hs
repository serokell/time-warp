-- | This module provides RPC capabilities. It allows to write scenarios over
-- distributed systems, which can then be launched as either real program or
-- emulation with network nastiness manually controlled.
--
-- Usage example:
--
-- @
-- sumMethod :: Monad m => Int -> Int -> ServerT m Int
-- sumMethod a b = return $ a + b
--
-- callSum :: Int -> Int -> Client Int
-- callSum = call "sum"
--
-- exampleLaunch :: (MonadRpc m, MonadTimed m, MonadIO m) => m ()
-- exampleLaunch = do
--     -- launch server
--     work (for 1 minute) $ do
--         idr <- serverTypeRestriction2
--         serve 1234 [method "sum" $ idr sumMethod]
--     -- make 3 requests with delay
--     fork_ $
--         forM_ [1..3] $
--             \\i -> do
--                 wait (for 3 sec)
--                 res <- execClient ("127.0.0.1", 1234) $ callSum (-1) i
--                 liftIO $ timestamp $ "Answer is " ++ show res
-- @
--
-- This scenario then can be launched as real program:
--
-- >>> runTimedIO . runMsgPackRpc $ exampleLaunch
-- [3000012µs] Answer is 0
-- [6000013µs] Answer is 1
-- [9000015µs] Answer is 2
--
-- Or as emulation, which works immediately:
--
-- >>> runTimedT . runPureRpc (mkStdGen 23423) (10 :: Microsecond, 50 :: Microsecond) $ exampleLaunch
-- [3000023µs] Answer is 0
-- [6000072µs] Answer is 1
-- [90000102µs] Answer is 2

module Control.TimeWarp.Rpc
       ( module Control.TimeWarp.Rpc.MonadRpc
       , module Control.TimeWarp.Rpc.MsgPackRpc
       , module Control.TimeWarp.Rpc.Restriction
       , module Control.TimeWarp.Rpc.PureRpc
       ) where

import           Control.TimeWarp.Rpc.MonadRpc
import           Control.TimeWarp.Rpc.MsgPackRpc
import           Control.TimeWarp.Rpc.PureRpc
import           Control.TimeWarp.Rpc.Restriction
