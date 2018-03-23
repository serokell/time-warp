{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TemplateHaskell           #-}

-- | Benchmark scenarious.

module Scenarios
    ( Scenario (..)
    , MonadOneWay

    , oneWay
    , simple
    , repeated
    , heavyweight
    ) where

import           Control.DeepSeq        (NFData, force)
import           Control.Exception      (evaluate)
import           Control.Monad          (forM_, void)
import           Control.Monad.Base     (MonadBase)
import           Control.Monad.Catch    (MonadCatch, MonadMask)
import           Control.Monad.Trans    (MonadIO (..))
import qualified Control.TimeWarp.Rpc   as N
import qualified Control.TimeWarp.Timed as T
import           Data.MessagePack       (MessagePack (..))
import           GHC.Generics           (Generic)

-- * Commons

data Scenario m = forall env. NFData env => Scenario
    { scenarioInit    :: m env
    , scenarioAction  :: env -> m ()
    , scenarioCleanup :: env -> m ()
    }

data Msg a = Msg
    { msgPayload :: a
    , msgSize    :: Int
    } deriving (Eq, Show, Generic)

instance NFData a => NFData (Msg a)

instance MessagePack a => MessagePack (Msg a) where
    toObject Msg{..} = toObject (msgPayload, replicate msgSize (7 :: Int))
    fromObject o = do
        (msgPayload, l :: [Int]) <- fromObject o
        let msgSize = length l
        return Msg{..}

N.mkRequest ''Msg ''()

-- * One way -scenarios

type MonadOneWay m =
    ( T.MonadTimed m
    , N.MonadRpc '[ N.RpcOptionMessagePack, N.RpcOptionNoReturn] m
    , MonadIO m
    , MonadBase IO m
    , MonadCatch m
    , NFData (T.ThreadId m)
    , MonadMask m
    )

oneWay
    :: MonadOneWay m
    => Int -> Int -> Scenario m
oneWay repetitions size =
    Scenario
    { scenarioInit = do

        serverTid <- T.fork $ do
            N.serve 1234
                [ N.Method $ \(msg :: Msg Int) -> do
                    void . liftIO $ evaluate $ force msg
                ]
        T.wait (T.for 1 T.ms)
        return serverTid

    , scenarioAction = \_ -> do
        forM_ [0 .. repetitions] $ \i -> do
            let msg = Msg{ msgPayload = i, msgSize = size }
            N.send ("127.0.0.1", 1234) msg

    , scenarioCleanup = \serverTid -> do
        T.killThread serverTid
        T.wait (T.for 1 T.ms)
    }

simple :: MonadOneWay m => Scenario m
simple = oneWay 1 1

repeated :: MonadOneWay m => Int -> Scenario m
repeated k = oneWay k 1

heavyweight :: MonadOneWay m => Int -> Scenario m
heavyweight size = oneWay 1 size

