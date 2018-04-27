{-# LANGUAGE AllowAmbiguousTypes  #-}
{-# LANGUAGE ConstraintKinds      #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE PolyKinds            #-}
{-# LANGUAGE Rank2Types           #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Facilitates work with 'MonadRpc''s options.

module Control.TimeWarp.Rpc.ExtOpts
    ( ExtendedRpcOptions (..)
    , withExtendedRpcOptions
    , (:<<) (..)
    , pickEvi

    , HasOption (..)
    , OptionPresence (..)
    , OptionJudgement (..)

    -- * Re-exports for convenience
    , C.Dict (..)
    ) where

import           Control.Monad.Base            (MonadBase)
import           Control.Monad.Catch           (MonadCatch, MonadMask, MonadThrow)
import           Control.Monad.Reader          (ReaderT (..), ask)
import           Control.Monad.Trans           (MonadIO, MonadTrans (..))
import           Control.Monad.Trans.Control   (MonadBaseControl (..))
import qualified Data.Constraint               as C
import           Data.Proxy                    (Proxy (..))

import           Control.TimeWarp.Logging      (WithNamedLogger)
import           Control.TimeWarp.Rpc.MonadRpc (Method (..), MonadRpc (..),
                                                RpcOptions (..), proxyOfArg)
import           Control.TimeWarp.Timed        (MonadTimed, ThreadId)


-- | @o :<< os@ is evidence of that @os@ options extend @o@ options.
data o :<< os = Evi
    (forall r. RpcConstraints os r => Proxy r -> C.Dict (RpcConstraints o r))

pickEvi :: (forall r. RpcConstraints os r => C.Dict (RpcConstraints o r))
    -> o :<< os
pickEvi dict = Evi $ \(Proxy :: Proxy r) -> (dict @r)

evidenceOf :: o :<< os -> Proxy r -> RpcConstraints os r C.:- RpcConstraints o r
evidenceOf (Evi evi) pr = C.Sub (evi pr)

-- | Allows a monad to impement 'MonadRpc' with extra requirements.
-- You have to provide an evidence of that excessive options induce
-- larger 'RpcConstraints'.
--
-- Example: @MsgPackRpc@ implements 'MonadRpc '[RpcOptionsMsgPack]',
-- and options are fixated by monad due to functional dependency.
-- If you need to instantiate 'MonadRpc '[RpcOptionsMsgPack, AnotherOption]',
-- use @ExtendedRpcOptions yourOptions instantiatedOptions MsgPackRpc@.
newtype ExtendedRpcOptions os o m a = ExtendedRpcOptions
    { unwrapExtendedRpcOptions :: ReaderT (o :<< os) m a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadThrow, MonadCatch, MonadMask
               , MonadTimed)

-- | Runner for 'ExtendedRpcOptions' monad.
--
-- Example of usage:
--
-- @
-- withExtendedRpcOptions (Evi Dict) $ someLogic
-- @
withExtendedRpcOptions
    :: o :<< os
    -> ExtendedRpcOptions os o m a
    -> m a
withExtendedRpcOptions dict (ExtendedRpcOptions action) = runReaderT action dict

type instance ThreadId (ExtendedRpcOptions o os m) = ThreadId m

instance (RpcOptions os, MonadRpc o m) => MonadRpc os (ExtendedRpcOptions os o m) where
    send addr (msg :: msg) =
        ExtendedRpcOptions . ReaderT $ \evi ->
        send addr msg C.\\ evidenceOf evi (Proxy @msg)

    serve port methods =
        ExtendedRpcOptions $ do
            evi <- ask
            serve port $ convert evi <$> methods
      where
        convert
            :: o :<< os
            -> Method os (ExtendedRpcOptions os o m)
            -> Method o (ReaderT (o :<< os) m)
        convert evi (Method f) =
            Method (unwrapExtendedRpcOptions . f) C.\\ evidenceOf evi (proxyOfArg f)

instance MonadTrans (ExtendedRpcOptions o os) where
    lift = ExtendedRpcOptions . lift

deriving instance MonadBase IO m => MonadBase IO (ExtendedRpcOptions o os m)
deriving instance (WithNamedLogger m, Monad m) => WithNamedLogger (ExtendedRpcOptions o os m)

instance MonadBaseControl IO m =>
         MonadBaseControl IO (ExtendedRpcOptions o os m) where
    type StM (ExtendedRpcOptions o os m) a = StM m a
    liftBaseWith f =
        ExtendedRpcOptions $
        liftBaseWith $ \runInIO -> f $ runInIO . unwrapExtendedRpcOptions
    restoreM = ExtendedRpcOptions . restoreM


data OptionPresence o os
    = OptionPresent (o :<< os)
    | OptionAbsent

class OptionJudgement o (os :: [*]) where
    isOptionPresent :: OptionPresence o os

instance OptionJudgement o '[] where
    isOptionPresent = OptionAbsent

instance {-# OVERLAPS #-} OptionJudgement o (o : os) where
    isOptionPresent = OptionPresent (pickEvi C.Dict)

instance OptionJudgement x os => OptionJudgement x (o : os) where
    isOptionPresent =
        case isOptionPresent @x @os of
            OptionAbsent            -> OptionAbsent
            OptionPresent (Evi evi) -> OptionPresent (Evi evi)


class HasOption o (os :: [*]) where
    hasOption :: o :<< os

instance {-# OVERLAPS #-} HasOption o (o : os) where
    hasOption = pickEvi C.Dict

instance HasOption x os => HasOption x (o : os) where
    hasOption = case hasOption @x @os of Evi evi -> Evi evi
