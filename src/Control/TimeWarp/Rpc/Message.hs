{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DefaultSignatures     #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}

-- |
-- Module      : Control.TimeWarp.Rpc.Message
-- Copyright   : (c) Serokell, 2016
-- License     : GPL-3 (see the file LICENSE)
-- Maintainer  : Serokell <hi@serokell.io>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module defines typeclasses which allow to abstragate from concrete serialization
-- strategy, and also `Message` type, which binds a name to request.
--
-- UPGRADE-NOTE: currently only `Binary` serialization is supported,
-- need to add support for /MessagePack/, /aeson/, /cereal/ e.t.c.

module Control.TimeWarp.Rpc.Message
       (
       -- * Message
         MessageName
       , Message (..)

       -- * Serialization and deserialization
       , PackingType (..)
       , Packable (..)
       , Unpackable (..)

       -- * Basic packing types
       , BinaryP (..)
       , plainBinaryP

       -- * Parts of message
       -- $message-parts
       , ContentData (..)
       , NameData (..)
       , RawData (..)
       , WithHeaderData (..)

       -- * Util
       , messageName'
       , runGetOrThrow
       ) where

import           Control.Monad.Catch               (MonadThrow (..))
import           Control.Monad.Extra               (unlessM)
import           Data.Binary                       (Binary (..))
import           Data.Binary.Get                   (Get, isEmpty, label, runGetOrFail)
import           Data.Binary.Put                   (runPut)
import           Data.ByteString                   (ByteString)
import qualified Data.ByteString.Lazy              as BL
import           Data.Conduit                      (Conduit, (=$=))
import qualified Data.Conduit.List                 as CL
import           Data.Conduit.Serialization.Binary (ParseError (..), conduitGet,
                                                    conduitPut)
import           Data.Data                         (Data, dataTypeName, dataTypeOf)
import           Data.Proxy                        (Proxy (..), asProxyTypeOf)
import qualified Data.Text                         as T
import           Data.Text.Buildable               (Buildable)
import           Data.Typeable                     (Typeable)
import qualified Formatting                        as F


-- * Message

-- | Message name, which is expected to uniquely define type of message.
type MessageName = T.Text

-- | Defines type with it's own `MessageName`.
class Typeable m => Message m where
    -- | Uniquely identifies this type
    messageName :: Proxy m -> MessageName
    default messageName :: Data m => Proxy m -> MessageName
    messageName proxy =
         T.pack . dataTypeName . dataTypeOf $ undefined `asProxyTypeOf` proxy

    -- | Description of message, for debug purposes
    formatMessage :: m -> T.Text
    default formatMessage :: Buildable m => m -> T.Text
    formatMessage = F.sformat F.build


-- * Parts of message.
-- $message-parts
-- This part describes different parts of message. which are enought for serializing
-- message / could be extracted on deserializing.
--
-- | Message's content.
data ContentData r = ContentData r

-- | Designates data given from incoming message, but not deserialized to any specified
-- object.
data RawData = RawData ByteString

-- | Message's name.
data NameData = NameData MessageName

-- | Message's header & something else
data WithHeaderData h r = WithHeaderData h r


-- * Util

-- | As `messageName`, but accepts message itself, may be more convinient is most cases.
messageName' :: Message m => m -> MessageName
messageName' = messageName . proxyOf
  where
    proxyOf :: a -> Proxy a
    proxyOf _ = Proxy

-- | Parses given bytestring, throwing `ParseError` on fail.
runGetOrThrow :: MonadThrow m => Get a -> BL.ByteString -> m a
runGetOrThrow p s =
    either (\(bs, off, err) -> throwM $ ParseError (BL.toStrict bs) off err)
           (\(_, _, a) -> return a)
        $ runGetOrFail p s

-- * Serialization and deserialization

-- | Defines a serialization / deserialization strategy.
-- Deserealization is assumed to be performed in two phases:
--
-- * byte stream -> intermediate form
--
-- * intermediate form -> any part of message (or their combination)
class PackingType p where
    -- | Defines intermediate form
    type IntermediateForm p :: *

    -- | Way of unpacking raw bytes to intermediate form.
    unpackMsg :: MonadThrow m => p -> Conduit ByteString m (IntermediateForm p)

-- | Defines a way to serialize object @r@ with given packing type @p@.
class PackingType p => Packable p r where
    -- | Way of packing data to raw bytes.
    packMsg :: MonadThrow m => p -> Conduit r m ByteString

-- | Defines a way to deserealize data with given packing type @p@ and extract object @r@.
class PackingType p => Unpackable p r where
    -- | Way to extract message part from intermediate form.
    extractMsgPart :: MonadThrow m => p -> IntermediateForm p -> m r


-- * Basic packing types

-- ** Binary

-- | Defines way to encode `Binary` instances into message of format
-- (header, [[name], content]), where [x] = (length of x, x).
-- /P/ here denotes to "packing".
data BinaryP header = BinaryP

plainBinaryP :: BinaryP ()
plainBinaryP = BinaryP

instance Binary h => PackingType (BinaryP h) where
    type IntermediateForm (BinaryP h) = WithHeaderData h RawData
    unpackMsg _ = conduitGet $ WithHeaderData <$> get <*> (RawData <$> get)

instance (Binary h, Binary r, Message r)
       => Packable (BinaryP h) (WithHeaderData h (ContentData r)) where
    packMsg p = CL.map packToRaw =$= packMsg p
      where
        packToRaw (WithHeaderData h (ContentData r)) =
            WithHeaderData h . RawData . BL.toStrict . runPut $ do
                put $ messageName' r
                put r

instance Binary h
      => Packable (BinaryP h) (WithHeaderData h RawData) where
    packMsg _ = CL.map doPut =$= conduitPut
      where
        doPut (WithHeaderData h (RawData r)) = put h >> put r


instance Binary h
      => Unpackable (BinaryP h) (WithHeaderData h RawData) where
    extractMsgPart _ = return

instance Binary h
      => Unpackable (BinaryP h) NameData where
    extractMsgPart _ (WithHeaderData _ (RawData raw)) =
        let labelName = "(in parseNameData)"
        in runGetOrThrow (NameData <$> label labelName get) $ BL.fromStrict raw

instance (Binary h, Binary r)
      => Unpackable (BinaryP h) (ContentData r) where
    extractMsgPart _ (WithHeaderData _ (RawData raw)) =
        runGetOrThrow parser $ BL.fromStrict raw
      where
        parser = checkAllConsumed $ label labelName $
            (get :: Get MessageName) *> (ContentData <$> get)
        checkAllConsumed p = p <* unlessM isEmpty (fail "unconsumed input")
        labelName = "(in parseNameNContentData)"
