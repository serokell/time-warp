{-# LANGUAGE ExplicitForAll        #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE ViewPatterns          #-}

-- | Defines network-emulated implementation of `MonadRpc`.
module Control.TimeWarp.Rpc.PureRpc
       ( PureRpc
       , runPureRpc
       , Delays (..)
       , DelaysSpecifier (..)
       , ConnectionOutcome (..)
       , getRandomTR
       ) where

import           Control.Exception.Base        (Exception)
import           Control.Lens                  (both, makeLenses, to, use, (%%=),
                                                (%~), at, (?=))
import           Control.Monad                 (forM_, when)
import           Control.Monad.Catch           (MonadCatch, MonadMask, MonadThrow, throwM)
import           Control.Monad.Random          (MonadRandom (getRandomR), Rand, runRand)
import           Control.Monad.State           (MonadState (get, put, state), StateT,
                                                evalStateT)
import           Control.Monad.Trans           (MonadIO, MonadTrans, lift)
import           Data.Default                  (Default, def)
import           Data.Map                      as Map
import           Data.Time.Units               (fromMicroseconds, toMicroseconds)
import           Data.Typeable                 (Typeable)
import           System.Random                 (StdGen)

import           Data.MessagePack              (Object)
import           Data.MessagePack.Object       (MessagePack, fromObject, toObject)

import           Control.TimeWarp.Logging      (WithNamedLogger)
import           Control.TimeWarp.Rpc.MonadRpc (Client (..), Host, Method (..),
                                                MonadRpc (execClient, serve),
                                                Port, RpcError (..), methodBody,
                                                methodName)
import           Control.TimeWarp.Timed        (Microsecond, MonadTimed (..),
                                                PureThreadId, TimedT, for,
                                                localTime, runTimedT, sleepForever,
                                                wait, ThreadId)

localhost :: Host
localhost = "127.0.0.1"

-- | Describes obstructions occured on executing RPC request.
data ConnectionOutcome
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
                -> Rand StdGen ConnectionOutcome
    }

-- | Describe network nastiness.
class DelaysSpecifier d where
    toDelays :: d -> Delays

instance DelaysSpecifier Delays where
    toDelays = id

-- | Connection is never established.
instance DelaysSpecifier () where
    toDelays = const . Delays . const . return $ NeverConnected

-- | Specifies permanent connection delay.
instance DelaysSpecifier Microsecond where
    toDelays = Delays . const . return . ConnectedIn

-- | Connection delay varies is specified range.
instance DelaysSpecifier (Microsecond, Microsecond) where
    toDelays = Delays . const . fmap ConnectedIn . getRandomTR

-- This is needed for QC.
instance Show Delays where
    show _ = "Delays"

-- | Describes reliable network.
instance Default Delays where
    def = Delays . const . return . ConnectedIn $ 0

-- | Return a randomly-selected time value in specified range.
getRandomTR :: MonadRandom m => (Microsecond, Microsecond) -> m Microsecond
getRandomTR = fmap fromMicroseconds . getRandomR . (both %~ toMicroseconds)

-- | Keeps servers' methods.
type Listeners m = Map.Map (Port, String) ([Object] -> m Object)

-- | Keeps global network information.
data NetInfo m = NetInfo
    { _listeners :: Listeners m
    , _randSeed  :: StdGen
    , _delays    :: Delays
    }

$(makeLenses ''NetInfo)

-- | Implementation of RPC protocol for emulation, allows to manually define
-- network nastiness via `Delays` datatype. TCP model is used. 
--
-- NOTE: List of known issues:
--
--     * Method, once being declared in net, can't be removed.
-- Even `throwTo` won't help.
newtype PureRpc m a = PureRpc
    { unwrapPureRpc :: TimedT (StateT (NetInfo (PureRpc m)) m) a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadThrow, MonadCatch,
                MonadMask, WithNamedLogger)

type instance ThreadId (PureRpc m) = PureThreadId

deriving instance (MonadIO m, MonadCatch m) => MonadTimed (PureRpc m)

instance MonadTrans PureRpc where
    lift = PureRpc . lift . lift

instance MonadState s m => MonadState s (PureRpc m) where
    get = lift get
    put = lift . put
    state = lift . state

-- | Launches distributed scenario, emulating work of network.
runPureRpc
    :: (MonadIO m, MonadCatch m, DelaysSpecifier delays)
    => StdGen -> delays -> PureRpc m a -> m a
runPureRpc _randSeed (toDelays -> _delays) rpc =
    evalStateT (runTimedT $ unwrapPureRpc rpc) net
  where
    net        = NetInfo{..}
    _listeners = Map.empty

request :: (Monad m, MonadThrow m, MessagePack a)
        => Client a
        -> Listeners (PureRpc m)
        -> Port
        -> PureRpc m a
request (Client name args) listeners' port =
    case Map.lookup (port, name) listeners' of
        Nothing -> throwM $ ServerError $ toObject $ mconcat
            ["method \"", name, "\" not found at port ", show port]
        Just f  -> do
            res <- f args
            case fromObject res of
                Nothing -> throwM $ ResultTypeError "type mismatch"
                Just r  -> return r


instance (MonadIO m, MonadCatch m) =>
         MonadRpc (PureRpc m) where
    execClient (host, port) cli =
        if host /= localhost
            then
                error "Can't emulate for host /= localhost"
            else do 
                waitDelay
                ls <- PureRpc $ use listeners
                request cli ls port
    serve port methods =
        PureRpc $
        do lift $
               forM_ methods $
               \Method {..} -> do
                    let methodRef = (port, methodName)
                    defined <- use $ listeners . to (Map.member methodRef)
                    when defined $ return ()
                    -- TODO:
                    --    throwM $ PortAlreadyBindedError port
                    listeners . at (port, methodName) ?= methodBody
           sleepForever

waitDelay
    :: (MonadThrow m, MonadIO m, MonadCatch m)
    => PureRpc m ()
waitDelay =
    PureRpc $
    do delays' <- use delays
       time    <- localTime
       delay   <- randSeed %%= runRand (evalDelay delays' time)
       case delay of
           ConnectedIn connDelay -> wait (for connDelay)
           NeverConnected        -> sleepForever

data PortAlreadyBindedError = PortAlreadyBindedError Port
    deriving (Show, Typeable)

instance Exception PortAlreadyBindedError
