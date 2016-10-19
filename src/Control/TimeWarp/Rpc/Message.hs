{-# LANGUAGE DefaultSignatures         #-}
{-# LANGUAGE TypeFamilies              #-}

-- |
-- Module      : Control.TimeWarp.Rpc.Message
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module defines `Message` type, which binds a name to request.

module Control.TimeWarp.Rpc.Message
       ( Message (..)
       ) where

import           Data.Binary   (Binary)
import           Data.Data     (Data, dataTypeName, dataTypeOf)
import           Data.Proxy    (Proxy, asProxyTypeOf)
import           Data.Typeable (Typeable)

class (Typeable m, Binary m) => Message m where
    messageName :: Proxy m -> String
    default messageName :: Data m => Proxy m -> String
    messageName proxy = dataTypeName . dataTypeOf $ undefined `asProxyTypeOf` proxy

instance Message () where
    messageName _ = "()"
