{-# LANGUAGE TemplateHaskell #-}

module Control.TimeWarp.Rpc.TH
    ( mkMessage
    ) where

import           Language.Haskell.TH

import           Control.TimeWarp.Rpc.MonadDialog    (Message (..))

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
