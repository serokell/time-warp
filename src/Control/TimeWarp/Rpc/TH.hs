{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE TemplateHaskell #-}

module Control.TimeWarp.Rpc.TH
    ( mkRequestWithErr
    , mkRequest
    ) where

import           Control.Monad                 (replicateM)
import           Data.Monoid                   ((<>))
import           Data.Void                     (Void)
import           Language.Haskell.TH

import           Control.TimeWarp.Rpc.MonadRpc (RpcRequest (..))

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
--     methodName _ = "<module name>.MyRequest"
-- @
mkRequestWithErr :: Name -> Name -> Name -> Q [Dec]
mkRequestWithErr reqName respName errName = do
    let reqType = reifyType reqName
        respType = reifyType respName
        errType = reifyType errName
    (:[]) <$> mkInstance reqType respType errType
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
        instanceD
        (cxt [])
        (appT (conT ''RpcRequest) reqType)
        [ typeFamily reqType ''Response      respType
        , typeFamily reqType ''ExpectedError errType
        , func
        ]

    typeFamily reqType typeFamilyName rvalueType = do
        rc <- reqType
        ct <- rvalueType
        return $ TySynInstD typeFamilyName (TySynEqn [rc] ct)

    func = return $ FunD 'methodName
        [ Clause [WildP] (NormalB . LitE . StringL $ show reqName) []
        ]

mkRequest :: Name -> Name -> Q [Dec]
mkRequest reqName respName = mkRequestWithErr reqName respName ''Void
