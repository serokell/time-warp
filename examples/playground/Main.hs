{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}

{-# LANGUAGE TypeOperators         #-}

module Main
    ( main

    , yohohoScenario
    , repeatedScenario

    , runEmulation
    , runEmulationWithDelays
    , runRealRpc
    , runRealUdp

    , runRepeatedScenarioWithRpc
    ) where

import           Control.Exception       (Exception)

import           Control.Monad           (forM_)
import           Control.Monad.Catch     (MonadCatch, throwM)
import           Control.Monad.Random    (newStdGen)
import           Control.Monad.Trans     (MonadIO (..))
import           Data.MessagePack.Object (MessagePack)
import           Data.Monoid             ((<>))
import           GHC.Generics            (Generic)

import           Control.TimeWarp.Rpc    (Delays, DelaysLayer (..), Dict (..),
                                          Method (..), MonadMsgPackRpc, MonadRpc (..),
                                          MsgPackRpc, MsgPackUdp, PureRpc,
                                          RpcOptionMessagePack, RpcOptionNoReturn,
                                          mkRequestAuto, mkRequestWithErrAuto, pickEvi,
                                          runDelaysLayer, runMsgPackRpc, runMsgPackUdp,
                                          runPureRpc, withExtendedRpcOptions)
import           Control.TimeWarp.Timed  (MonadTimed (wait), for, ms, sec, sec', till,
                                          virtualTime, work)

main :: IO ()
main = return ()  -- use ghci

runRealRpc :: MsgPackRpc a -> IO a
runRealRpc = runMsgPackRpc

runRealUdp :: MsgPackUdp a -> IO a
runRealUdp = runMsgPackUdp

runEmulation :: PureRpc IO a -> IO a
runEmulation scenario = runPureRpc scenario

runEmulationWithDelays :: Delays -> DelaysLayer (PureRpc IO) a -> IO a
runEmulationWithDelays delays scenario = do
    gen <- newStdGen
    runPureRpc $ runDelaysLayer delays gen scenario

-- * data types

data EpicRequest = EpicRequest
    { num :: Int
    , msg :: String
    } deriving (Generic, MessagePack)

data EpicException = EpicException String
    deriving (Show, Generic, MessagePack)

instance Exception EpicException

$(mkRequestWithErrAuto ''EpicRequest ''String ''EpicException)

-- * scenarios

yohohoScenario :: (MonadTimed m, MonadMsgPackRpc m, MonadIO m) => m ()
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

data Msg = Msg Int
    deriving (Generic, MessagePack)

$(mkRequestAuto ''Msg ''())

repeatedScenario :: (MonadTimed m, MonadRpc '[RpcOptionMessagePack, RpcOptionNoReturn] m, MonadIO m, MonadCatch m) => m ()
repeatedScenario  = do
    work (for 11 sec) $
        serve 1234
            [Method $ \(Msg i) -> do
                time <- virtualTime
                liftIO $ putStrLn ("[" <> show time <> "] " <> "Lol " <> show i)
            ]

    wait (for 100 ms)
    forM_ [0..9] $ \i -> do
        send ("127.0.0.1", 1234) (Msg i)
        wait (for 1 sec)

    wait (till 12 sec)

-- | Example of how to use 'withExtendedRpcOptions'.
runRepeatedScenarioWithRpc :: IO ()
runRepeatedScenarioWithRpc = runRealRpc $ withExtendedRpcOptions (pickEvi Dict) repeatedScenario
