{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}

module Main
    ( main
    , yohohoScenario
    , repeatedScenario
    , runEmulation
    , runEmulationWithDelays
    , runReal
    ) where

import           Control.Exception       (Exception)

import           Control.Monad           (forM_)
import           Control.Monad.Catch     (MonadCatch, throwM)
import           Control.Monad.Random    (newStdGen)
import           Control.Monad.Trans     (MonadIO (..))
import           Data.MessagePack.Object (MessagePack)
import           Data.Monoid             ((<>))
import           GHC.Generics            (Generic)

import           Control.TimeWarp.Rpc    (Delays, DelaysLayer (..), Method (..),
                                          MonadMsgPackRpc, MonadRpc (..), MsgPackRpc,
                                          PureRpc, mkRequest, mkRequestWithErr,
                                          runDelaysLayer, runMsgPackRpc, runPureRpc,
                                          submit)
import           Control.TimeWarp.Timed  (MonadTimed (wait), for, ms, sec, sec',
                                          virtualTime, work)

main :: IO ()
main = return ()  -- use ghci

runReal :: MsgPackRpc a -> IO a
runReal = runMsgPackRpc

runEmulation :: PureRpc IO a -> IO a
runEmulation scenario = runPureRpc scenario

runEmulationWithDelays :: DelaysLayer (PureRpc IO) a -> Delays -> IO a
runEmulationWithDelays scenario delays = do
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

$(mkRequestWithErr ''EpicRequest ''String ''EpicException)

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

$(mkRequest ''Msg ''())

repeatedScenario :: (MonadTimed m, MonadMsgPackRpc m, MonadIO m, MonadCatch m) => m ()
repeatedScenario  = do
    work (for 12 sec) $
        serve 1234
            [Method $ \(Msg i) -> do
                time <- virtualTime
                liftIO $ putStrLn ("[" <> show time <> "] " <> "Lol " <> show i)
            ]

    wait (for 100 ms)
    forM_ [0..9] $ \i -> do
        submit ("127.0.0.1", 1234) (Msg i)
        wait (for 1 sec)
