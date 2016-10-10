{-# LANGUAGE TemplateHaskell #-}

module Control.TimeWarp.Rpc.TH
    ( mkRequest
    ) where

import           Language.Haskell.TH

import           Control.TimeWarp.Rpc.MonadRpc    (Request (..))

-- | Generates `Request` instance by given names of request, response and
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
-- instance Request MyRequest where
--     type Response      MyRequest = MyResponse
--     type ExpectedError MyRequest = MyError
--     methodName _ = "<module name>.MyRequest"
-- @

mkRequest :: Name -> Q [Dec]
mkRequest reqType =
    (:[]) <$> mkInstance
  where
    mkInstance =
        instanceD
        (cxt [])
        (appT (conT ''Request) (conT reqType))
        [func]

    func = return $ FunD 'methodName
        [ Clause [WildP] (NormalB . LitE . StringL $ show reqType) []
        ]
