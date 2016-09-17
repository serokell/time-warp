{-# LANGUAGE ExplicitForAll        #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}

-- Defines pure implementation of `MonadRpc`.
module Control.TimeWarp.Rpc.PureRpc
       ( PureRpc
       , runPureRpc
       , runPureRpc_
       , Delays (..)
       , ConnectionSuccess (..)
       , getRandomTR
       ) where

import           Control.Exception.Base        (Exception)
import           Control.Lens                  (makeLenses, use, (%%=), (%=),
                                                (%~), both, to)
import           Control.Monad                 (forM_)
import           Control.Monad.Catch           (MonadCatch, MonadMask,
                                                MonadThrow, throwM)
import           Control.Monad.Random          (Rand, runRand,
                                                MonadRandom (getRandomR))
import           Control.Monad.State           (MonadState (get, put, state),
                                                StateT, evalStateT)
import           Control.Monad.Trans           (MonadIO, MonadTrans, lift)
import           Data.Default                  (Default, def)
import           Data.Map                      as Map
import           Data.Time.Units               (toMicroseconds,
                                                fromMicroseconds)
import           Data.Typeable                 (Typeable)
import           System.Random                 (StdGen)

import           Data.MessagePack              (Object)
import           Data.MessagePack.Object       (MessagePack, fromObject,
                                                toObject)

import           Control.TimeWarp.Logging      (WithNamedLogger)
import           Control.TimeWarp.Rpc.MonadRpc (Client (..), Host, Method (..),
                                                MonadRpc (execClient, serve),
                                                NetworkAddress, RpcError (..),
                                                methodBody, methodName)
import           Control.TimeWarp.Timed        (Microsecond, MonadTimed (..),
                                                TimedT, evalTimedT, for, mcs,
                                                localTime, runTimedT,
                                                wait, PureThreadId,
                                                sleepForever)

localhost :: Host
localhost = "127.0.0.1"

-- | Describes obstructions occured on executing RPC request.
data ConnectionSuccess
    -- | Connection established in specified amout of time.
    = ConnectedIn Microsecond
    -- | Connection would be never established, client hangs.
    | NeverConnected

-- @TODO Remove these hard-coded values

-- | Describes network nastyness.
--
-- Examples:
--
-- * Always 1 second delay:
--
-- @
-- Delays $ \\_ -> return $ ConnectedIn (interval 1 sec)
-- @
--
-- * Delay varies between 1 and 5 seconds (with granularity of 1 mcs):
--
-- @
-- Delays $ \\_ -> ConnectedIn \<$\> getRandomTR (interval 1 sec, interval 5 sec)
-- @
--
-- * For first 10 seconds connection is established with probability of 1/6:
--
-- @
-- Delays $ \\time -> do
--     p <- getRandomR (0, 5)
--     if (p == 0) && (time <= interval 10 sec)
--         then return $ ConnectedIn 0
--         else return NeverConnected
-- @
newtype Delays = Delays
    { -- | Basing on current virtual time, returns delay after which server
      -- receives RPC request.
      evalDelay :: Microsecond
                -> Rand StdGen ConnectionSuccess
    }

-- This is needed for QC.
instance Show Delays where
    show _ = "Delays"

-- | Descirbes reliable network.
instance Default Delays where
    def = Delays . const . return . ConnectedIn $ 0

-- | Return a randomly-selected time value in specified range.
getRandomTR :: MonadRandom m => (Microsecond, Microsecond) -> m Microsecond
getRandomTR = fmap fromMicroseconds . getRandomR . (both %~ toMicroseconds)

-- | Keeps servers' methods.
type Listeners m = Map.Map (NetworkAddress, String) ([Object] -> m Object)

-- | Keeps global network information.
data NetInfo m = NetInfo
    { _listeners :: Listeners m
    , _randSeed  :: StdGen
    , _delays    :: Delays
    }

$(makeLenses ''NetInfo)

-- | Pure implementation of RPC. TCP model is used.
-- Network nastiness of emulated system can be manually defined via `Delays`
-- datatype.
--
-- NOTE: List of known issues:
--
--     * Method, once being declared in net, can't be removed.
-- Even `throwTo` won't help.
-- Status: not relevant in tests for now. May be fixed in presence of `MVar`.

newtype PureRpc m a = PureRpc
    { unwrapPureRpc :: StateT Host (TimedT (StateT (NetInfo (PureRpc m)) m)) a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadThrow, MonadCatch,
                MonadMask)

-- | Implementation refers to `Control.TimeWarp.Timed.TimedT.TimedT`.
instance (MonadIO m, MonadCatch m, WithNamedLogger m) =>
         MonadTimed (PureRpc m) where
    type ThreadId (PureRpc m) = PureThreadId

    localTime = PureRpc localTime

    wait = PureRpc . wait

    fork = PureRpc . fork . unwrapPureRpc

    myThreadId = PureRpc myThreadId

    throwTo tid = PureRpc . throwTo tid

    timeout t = PureRpc . timeout t . unwrapPureRpc

instance MonadTrans PureRpc where
    lift = PureRpc . lift . lift . lift

instance MonadState s m => MonadState s (PureRpc m) where
    get = lift get
    put = lift . put
    state = lift . state

-- | Launches distributed scenario, emulating work of network.
runPureRpc
    :: (MonadIO m, MonadCatch m)
    => StdGen -> Delays -> PureRpc m a -> m a
runPureRpc _randSeed _delays (PureRpc rpc) =
    evalStateT (evalTimedT (evalStateT rpc localhost)) net
  where
    net        = NetInfo{..}
    _listeners = Map.empty

-- | Launches distributed scenario without result.
-- May be slightly more efficient.
runPureRpc_
    :: (MonadIO m, MonadCatch m)
    => StdGen -> Delays -> PureRpc m () -> m ()
runPureRpc_ _randSeed _delays (PureRpc rpc) =
    evalStateT (runTimedT (evalStateT rpc localhost)) net
  where
    net        = NetInfo{..}
    _listeners = Map.empty

request :: (Monad m, MonadThrow m, MessagePack a)
        => Client a
        -> Listeners (PureRpc m)
        -> NetworkAddress
        -> PureRpc m a
request (Client name args) listeners' addr =
    case Map.lookup (addr, name) listeners' of
        Nothing -> throwM $ ServerError $ toObject $ mconcat
            ["method \"", name, "\" not found at adress ", show addr]
        Just f  -> do
            res <- f args
            case fromObject res of
                Nothing -> throwM $ ResultTypeError "type mismatch"
                Just r  -> return r


instance (WithNamedLogger m, MonadIO m, MonadCatch m) =>
         MonadRpc (PureRpc m) where
    execClient addr cli =
        PureRpc $
        do curHost <- get
           unwrapPureRpc $ waitDelay
           ls <- lift . lift $ use listeners
           put $ fst addr
           answer <- unwrapPureRpc $ request cli ls addr
           put curHost
           return answer
    serve port methods =
        PureRpc $
        do host <- get
           lift $
               lift $
               forM_ methods $
               \Method {..} -> do
                    let methodRef = ((host, port), methodName)
                    defined <- use $ listeners . to (Map.member methodRef)
                    -- TODO:
--                    when defined $
--                        throwM $ PortAlreadyBindedError (host, port)
                    listeners %=
                        Map.insert ((host, port), methodName) methodBody
           sleepForever

waitDelay
    :: (WithNamedLogger m, MonadThrow m, MonadIO m, MonadCatch m)
    => PureRpc m ()
waitDelay =
    PureRpc $
    do delays' <- lift . lift $ use delays
       time    <- localTime
       delay   <- lift . lift $ randSeed %%=
            runRand (evalDelay delays' time)
       case delay of
           ConnectedIn connDelay -> wait (for connDelay mcs)
           NeverConnected        -> sleepForever

data PortAlreadyBindedError = PortAlreadyBindedError NetworkAddress
    deriving (Show, Typeable)

instance Exception PortAlreadyBindedError
