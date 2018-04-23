{-# LANGUAGE TemplateHaskell #-}

module Control.TimeWarp.Rpc.TH
    ( mkRequestWithErr
    , mkRequest

    , mkRequestWithErrAuto
    , mkRequestAuto
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
-- $(mkRequest ''MyRequest ''MyResponse ''MyError 7)
-- @
--
-- generates
--
-- @
-- instance RpcRequest MyRequest where
--     type Response      MyRequest = MyResponse
--     type ExpectedError MyRequest = MyError
--     messageId _ = MessageId 7
-- @
mkRequestWithErr :: Name -> Name -> Name -> MessageId -> Q [Dec]
mkRequestWithErr reqName respName errName (MessageId msgId) = do
    let reqType = reifyType reqName
        respType = reifyType respName
        errType = reifyType errName
    mkInstance reqType respType errType
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

    mkInstance reqType respType errType =
        [d|
        instance RpcRequest $reqType where
            type Response $reqType = $respType
            type ExpectedError $reqType = $errType

            messageId _ = MessageId $(lift msgId)
         |]

mkRequest :: Name -> Name -> MessageId -> Q [Dec]
mkRequest reqName respName msgId = mkRequestWithErr reqName respName ''Void msgId

-- | Simplified version of 'mkRequestWithErr', assignes unique 'MessageId's
-- automatically.
-- Note, it wreaks a backward compatibilty, and also works badly
-- when actually several executables are launched.
mkRequestWithErrAuto :: Name -> Name -> Name -> Q [Dec]
mkRequestWithErrAuto reqName respName errName = do
    msgId <- runIO getNextMessageId
    mkRequestWithErr reqName respName errName msgId

mkRequestAuto :: Name -> Name -> Q [Dec]
mkRequestAuto reqName respName = do
    msgId <- runIO getNextMessageId
    mkRequest reqName respName msgId
