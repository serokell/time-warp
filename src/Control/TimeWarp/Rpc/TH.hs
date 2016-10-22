{-# LANGUAGE TemplateHaskell #-}

module Control.TimeWarp.Rpc.TH
    ( mkRequest
    ) where

import           Language.Haskell.TH

import           Control.TimeWarp.Rpc.MonadRpc       (Request (..))

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
