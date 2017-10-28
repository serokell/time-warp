{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}

module Main
    ( main
    , yohohoScenario
    , runEmulation
    , runReal
    ) where

import          Control.Exception           (Exception)

import          Control.Monad.Catch         (throwM)
import          Control.Monad.Random        (newStdGen)
import          Control.Monad.Trans         (MonadIO (..))
import          Data.MessagePack.Object     (MessagePack)
import          GHC.Generics                (Generic)

import          Control.TimeWarp.Timed      (MonadTimed (wait), sec, ms, sec', work,
                                             interval, for, Microsecond)
import          Control.TimeWarp.Rpc        (MonadRpc (..), MsgPackRpc, PureRpc,
                                             runMsgPackRpc, runPureRpc,
                                             Method (..), mkRequestWithErr)

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

-- * data types

data EpicRequest = EpicRequest
    { num :: Int
    , msg :: String
    } deriving (Generic, MessagePack)

data EpicException = EpicException String
    deriving (Show, Generic, MessagePack)

instance Exception EpicException

$(mkRequestWithErr ''EpicRequest ''String ''EpicException)

-- * scenarios

yohohoScenario :: (MonadTimed m, MonadRpc m, MonadIO m) => m ()
yohohoScenario = do
    work (for 5 sec) $
        serve 1234 [method]

    wait (for 100 ms)
    res <- send ("127.0.0.1", 1234) $
        EpicRequest 14 " men on the dead man's chest"

    liftIO $ print res
  where 
    method = Method $ \EpicRequest{..} -> do
        liftIO $ putStrLn "Got request, forming answer..."
        wait (for 0.1 sec')
        _ <- throwM $ EpicException "kek"
        return $ show (num + 1) ++ msg
