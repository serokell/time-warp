{-# LANGUAGE TemplateHaskell #-}

module Control.TimeWarp.Rpc.TH
    ( mkMessage
    , mkRequest
    , mkRequest'
    ) where

import           Language.Haskell.TH

import           Control.TimeWarp.Rpc.MonadDialog    (Message (..))
import           Control.TimeWarp.Rpc.MonadRpc       (Request (..))

-- | Generates `Message` instance for given datatype.
--
-- The following code
--
-- @
-- $(mkMessage ''MyRequest)
-- @
--
-- generates
--
-- @
-- instance Message MyMessage where
--     methodName _ = "<module name>.MyMessage"
-- @

mkMessage :: Name -> Q [Dec]
mkMessage reqType =
    (:[]) <$> mkInstance
  where
    mkInstance =
        instanceD
        (cxt [])
        (appT (conT ''Message) (conT reqType))
        [func]

    func = return $ FunD 'methodName
        [ Clause [WildP] (NormalB . LitE . StringL $ show reqType) []
        ]


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
-- instance Request MyRequest wherea
--     type Response      MyRequest = MyResponse
--     type ExpectedError MyRequest = MyError
-- @

mkRequest :: Name -> Name -> Name -> Q [Dec]
mkRequest reqType respType errType =
    (:[]) <$> mkInstance
  where
    mkInstance =
        instanceD
        (cxt [])
        (appT (conT ''Request) (conT reqType))
        [ typeFamily ''Response      respType
        , typeFamily ''ExpectedError errType
        ]

    typeFamily n t = do
        rc <- conT reqType
        ct <- conT t
        return $ TySynInstD n (TySynEqn [rc] ct)

-- | Creates both instances of `Message` and `Request`.
mkRequest' :: Name -> Name -> Name -> Q [Dec]
mkRequest' reqType respType errType =
    (++) <$> mkMessage reqType <*> mkRequest reqType respType errType
