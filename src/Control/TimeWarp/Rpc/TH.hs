{-# LANGUAGE TemplateHaskell #-}

module Control.TimeWarp.Rpc.TH
    ( mkRequestWithErr
    , mkRequest
    ) where

import           Control.Concurrent.STM        (atomically)
import           Control.Concurrent.STM.TVar   (TVar, newTVarIO, readTVar, writeTVar)
import           Control.Monad                 (replicateM)
import           Data.Monoid                   ((<>))
import           Data.Void                     (Void)
import           GHC.IO.Unsafe                 (unsafePerformIO)
import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax    (lift)

import           Control.TimeWarp.Rpc.MonadRpc (MessageId (..), RpcRequest (..))

-- | Counts used message ids.
messageIdCounter :: TVar Int
messageIdCounter = unsafePerformIO $ newTVarIO 0
{-# NOINLINE messageIdCounter #-}

-- | Acquires next free message id.
getNextMessageId :: IO MessageId
getNextMessageId = fmap MessageId . atomically $ do
    msgId <- readTVar messageIdCounter
    writeTVar messageIdCounter (msgId + 1)
    return msgId

-- | Generates `RpcRequest` instance by given names of request, response and
-- expected exception types.
--
-- The following code
--
-- @
-- $(mkRequest ''MyRequest ''MyResponse ''MyError)
-- @
--
-- generates
--
-- @
-- instance RpcRequest MyRequest where
--     type Response      MyRequest = MyResponse
--     type ExpectedError MyRequest = MyError
--     messageId _ = <some unique number>
-- @
--
-- Note that message ids are assigned in no determined order,
-- if backward compatibilty is required one has to define message codes manually.
mkRequestWithErr :: Name -> Name -> Name -> Q [Dec]
mkRequestWithErr reqName respName errName = do
    let reqType = reifyType reqName
        respType = reifyType respName
        errType = reifyType errName
    MessageId msgId <- runIO getNextMessageId
    mkInstance reqType respType errType msgId
  where
    reifyType :: Name -> Q Type
    reifyType name = reify name >>= \case
        TyConI (DataD _ dname typeVars _ _ _) -> reifyType' dname typeVars
        TyConI (NewtypeD _ nname typeVars _ _ _) -> reifyType' nname typeVars
        TyConI (TySynD tname typeVars _) -> reifyType' tname typeVars
        TyConI (DataFamilyD fname typeVars _) -> reifyType' fname typeVars
        _ -> fail $ "Type " <> show name <> " not found. "

    reifyType' :: Name -> [TyVarBndr] -> Q Type
    reifyType' typeConName typeVars = do
        typeArgs <- replicateM (length typeVars) $ VarT <$> newName "a"
        pure $ foldl AppT (ConT typeConName) typeArgs

    mkInstance reqType respType errType msgId =
        [d|
        instance RpcRequest $reqType where
            type Response $reqType = $respType
            type ExpectedError $reqType = $errType

            messageId _ = MessageId $(lift msgId)
         |]

mkRequest :: Name -> Name -> Q [Dec]
mkRequest reqName respName = mkRequestWithErr reqName respName ''Void
