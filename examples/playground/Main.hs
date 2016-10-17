{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}

module Main
    ( main
    , yohohoScenario
    , rpcScenario
--    , runEmulation
--    , runReal
    ) where

import          Control.Monad.Trans         (MonadIO (..))
import          Data.Binary                 (Binary, get, put)
import          Data.MessagePack.Class      (MessagePack (..))
import          Data.Void                   (Void, absurd)
import          GHC.Generics                (Generic)

import          Control.TimeWarp.Timed      (MonadTimed (wait), ms, sec', work,
                                             for, Second, till)
import          Control.TimeWarp.Rpc        (MonadRpc (..), localhost, Listener (..),
                                             mkMessage, Port, NetworkAddress, send,
                                             listen, MonadDialog,
                                             Method (..), mkRequest)

main :: IO ()
main = return ()  -- use ghci

{-
runReal :: MsgPackRpc a -> IO a
runReal = runMsgPackRpc

runEmulation :: PureRpc IO a -> IO a
runEmulation scenario = do
    gen <- newStdGen
    runPureRpc delays gen scenario
  where
    delays :: Microsecond
    delays = interval 50 ms
-}

-- * data types

data Ping = Ping
    deriving (Generic, Binary)
$(mkMessage ''Ping)

instance MessagePack Ping where
    toObject _ = toObject ()
    fromObject _ = pure Ping

data Pong = Pong
    deriving (Generic, Binary)
$(mkMessage ''Pong)

instance MessagePack Pong where
    toObject _ = toObject ()
    fromObject _ = pure Pong


$(mkMessage ''Void)

instance Binary Void where
    get = return undefined
    put = absurd

$(mkRequest ''Ping ''Pong ''Void)

data EpicRequest = EpicRequest
    { num :: Int
    , msg :: String
    } deriving (Generic, Binary)
$(mkMessage ''EpicRequest)

instance MessagePack EpicRequest where
    toObject EpicRequest{..} = toObject (num, msg)
    fromObject o = uncurry EpicRequest <$> fromObject o

-- * scenarios

guy :: Int -> NetworkAddress
guy = (localhost, ) . guysPort

guysPort :: Int -> Port
guysPort = (+10000)

-- Emulates dialog of two guys:
-- 1: Ping
-- 2: Pong
-- 1: EpicRequest ...
-- 2: <prints result>
yohohoScenario :: (MonadTimed m, MonadDialog m, MonadIO m) => m ()
yohohoScenario = do
    -- guy 1
    work (till finish) $
        listen (guysPort 2)
            [ Listener $ \Ping ->
                -- can send an answer
                send (guy 1) Pong

            , Listener $ \EpicRequest{..} ->
              do wait (for 0.1 sec')
                 -- can do IO
                 liftIO . putStrLn $ show (num + 1) ++ msg
            ]

    -- guy 2
    work (till finish) $
        listen (guysPort 1)
            [ Listener $ \Pong ->
                -- can send another request
                send (guy 2) $ EpicRequest 14 " men on the dead man's chest"
            ]

    -- guy 1 initiates dialog
    wait (for 100 ms)
    send (guy 2) Ping
    wait (till finish)
  where
    finish :: Second
    finish = 1

rpcScenario :: (MonadTimed m, MonadRpc m, MonadIO m) => m ()
rpcScenario = do
    work (till finish) $
        serve 1234 [ Method $ \Ping -> return Pong
                   ]

    wait (for 100 ms)
    Pong <- call (localhost, 1234) Ping
    return ()
  where
    finish :: Second
    finish = 5
