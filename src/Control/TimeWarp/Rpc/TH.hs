{-# LANGUAGE TemplateHaskell #-}

module Control.TimeWarp.Rpc.TH
    ( mkRequest
    ) where

import           Language.Haskell.TH

import           Control.TimeWarp.Rpc.MonadRpc    (RpcRequest (..))

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

mkRequest :: Name -> Name -> Name -> Q [Dec]
mkRequest reqType respType errType =
    (:[]) <$> mkInstance
  where
    mkInstance =
        instanceD
        (cxt [])
        (appT (conT ''RpcRequest) (conT reqType))
        [ typeFamily ''Response      respType
        , typeFamily ''ExpectedError errType
        , func
        ]

    typeFamily n t = do
        rc <- conT reqType
        ct <- conT t
        return $ TySynInstD n (TySynEqn [rc] ct)

    func = return $ FunD 'methodName
        [ Clause [WildP] (NormalB . LitE . StringL $ show reqType) []
        ]
