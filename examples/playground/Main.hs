{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Main
    ( main
    , myScenario
    , runEmulation
    , runReal
    ) where

import          Control.Exception           (Exception)

import          Control.Monad.Catch         (MonadCatch, throwM)
import          Control.Monad.Random        (newStdGen)
import          Control.Monad.Trans         (MonadIO (..))
import          Data.MessagePack.Object     (MessagePack (..))

import          Control.TimeWarp.Timed      (MonadTimed (wait), sec, ms, sec', work,
                                             interval, for, Microsecond)
import          Control.TimeWarp.Rpc        (MonadRpc (..), MsgPackRpc, PureRpc,
                                             runMsgPackRpc, runPureRpc,
                                             TransmissionPair (..), Method (..))

main :: IO ()
main = return ()  -- use ghci

runReal :: MsgPackRpc a -> IO a
runReal = runMsgPackRpc

runEmulation :: PureRpc IO a -> IO a
runEmulation scenario = do
    gen <- newStdGen
    runPureRpc delays gen scenario
  where
    delays :: Microsecond
    delays = interval 50 ms

data EpicRequest = EpicRequest
    { num :: Int
    , msg :: String
    }

data EpicException = EpicException String
    deriving Show

instance Exception EpicException

instance MessagePack EpicException where
    toObject (EpicException s) = toObject s
    fromObject = fmap EpicException . fromObject

instance MessagePack EpicRequest where
    toObject (EpicRequest a1 a2) = toObject (a1, a2)
    fromObject o = do (a1, a2) <- fromObject o
                      return $ EpicRequest a1 a2

instance TransmissionPair EpicRequest [Char] EpicException where
    methodName = const "EpicRequest"

myScenario :: (MonadTimed m, MonadRpc m, MonadIO m, MonadCatch m) => m ()
myScenario = do
    work (for 5 sec) $
        serve 1234 [method]

    wait (for 5 ms)
    res <- send ("127.0.0.1", 1234) $
        EpicRequest 14 " men on the dead man's chest"

    liftIO $ print res
  where 
    method = Method $ \EpicRequest{..} -> do
        liftIO $ putStrLn "Got request, forming answer..."
        wait (for 0.1 sec')
        _ <- throwM $ EpicException "kek"
        return $ show (num + 1) ++ msg
