{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DefaultSignatures     #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE ViewPatterns          #-}

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
       , NameNContentData (..)
       , RawData (..)
       , HeaderData (..)
       , HeaderNNameData (..)
       , HeaderNRawData (..)
       , HeaderNContentData (..)
       , HeaderNNameNContentData (..)

       -- * Util
       , messageName'
       ) where

import           Control.Lens                      ((<&>))
import           Control.Monad                     (when)
import           Control.Monad.Catch               (MonadThrow (..))
import           Data.Binary                       (Binary (..))
import           Data.Binary.Get                   (Decoder (..), Get, label, pushChunk,
                                                    runGet, runGetIncremental,
                                                    runGetOrFail)
import           Data.Binary.Put                   (runPut)
import           Data.ByteString                   (ByteString)
import qualified Data.ByteString                   as BS
import qualified Data.ByteString.Lazy              as BL
import           Data.Conduit                      (Conduit, await, leftover, yield,
                                                    (=$=))
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

-- | Message's header.
data HeaderData h = HeaderData h

-- | Message's header & content.
data HeaderNContentData h r = HeaderNContentData h r

-- | Message's header & remaining part in raw form.
data HeaderNRawData h = HeaderNRawData h RawData

-- | Message's header & name.
data HeaderNNameData h = HeaderNNameData h MessageName

-- | Message's name & content.
data NameNContentData r = NameNContentData MessageName r

-- | Message's header, name & content.
data HeaderNNameNContentData h r = HeaderNNameNContentData h MessageName r


-- * Util

-- | As `messageName`, but accepts message itself, may be more convinient is most cases.
messageName' :: Message m => m -> MessageName
messageName' = messageName . proxyOf
  where
    proxyOf :: a -> Proxy a
    proxyOf _ = Proxy


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
    -- | Way of packing data to raw bytes. At the moment when value gets passed
    -- downstream, all unconsumed input should be `leftover`ed.
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
    type IntermediateForm (BinaryP h) = HeaderNRawData h
    unpackMsg _ = conduitGet $ HeaderNRawData <$> get <*> (RawData <$> get)

instance (Binary h, Binary r, Message r)
       => Packable (BinaryP h) (HeaderNContentData h r) where
    packMsg p = CL.map packToRaw =$= packMsg p
      where
        packToRaw (HeaderNContentData h r) =
            HeaderNRawData h . RawData . BL.toStrict . runPut $ do
                put $ messageName' r
                put r

instance Binary h
      => Packable (BinaryP h) (HeaderNRawData h) where
    packMsg _ = CL.map doPut =$= conduitPut
      where
        doPut (HeaderNRawData h (RawData r)) = put h >> put r


instance Binary h
      => Unpackable (BinaryP h) (HeaderNRawData h) where
    extractMsgPart _ = return

parseNameNContentData :: (MonadThrow m, Binary r)
                      => HeaderNRawData h -> m (NameNContentData r)
parseNameNContentData (HeaderNRawData _ (RawData raw)) =
            case rawE of
              Left (BL.toStrict -> bs, off, err) -> throwM $ ParseError bs off $
                  "parseNNameContentData: " ++ err
              Right (bs, off, a)  ->
                  if BL.null bs
                     then return a
                     else throwM $ ParseError (BL.toStrict bs) off $
                         "parseHeaderNNameContentNData: unconsumed input"
          where
            rawE = runGetOrFail (NameNContentData <$> get <*> get) $ BL.fromStrict raw


instance Binary h
      => Unpackable (BinaryP h) NameData where
    extractMsgPart _ (HeaderNRawData _ (RawData raw)) =
        let labelName = "(in instance Unpackable BinaryP NameData)"
        in return $ runGet (NameData <$> label labelName get) $ BL.fromStrict raw

instance (Binary h, Binary r)
      => Unpackable (BinaryP h) (ContentData r) where
    extractMsgPart _ m = parseNameNContentData m <&>
        \(NameNContentData _ c) -> ContentData c
