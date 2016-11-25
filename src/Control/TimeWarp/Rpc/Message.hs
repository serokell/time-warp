{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DefaultSignatures     #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE TypeFamilies          #-}
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
       , Packable (..)
       , Unpackable (..)

       -- * Basic packing types
       , BinaryP (..)

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
       , intangibleSink
       , proxyOf
       ) where

import           Control.Monad                     (forM, mapM_, when)
import           Control.Monad.Catch               (MonadThrow (..))
import           Control.Monad.Trans               (MonadIO (..))
import           Data.Binary                       (Binary (..))
import           Data.Binary.Get                   (Decoder (..), Get, pushChunk, runGet,
                                                    runGetIncremental)
import           Data.Binary.Put                   (runPut)
import           Data.ByteString                   (ByteString)
import qualified Data.ByteString                   as BS
import qualified Data.ByteString.Lazy              as BL
import           Data.Conduit                      (Conduit, Consumer, await,
                                                    awaitForever, leftover, yield, (=$=))
import qualified Data.Conduit.List                 as CL
import           Data.Conduit.Serialization.Binary (ParseError (..), conduitPut)
import           Data.Data                         (Data, dataTypeName, dataTypeOf)
import           Data.IORef                        (modifyIORef, newIORef, readIORef)
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

-- | Constructs proxy of given type.
proxyOf :: a -> Proxy a
proxyOf _ = Proxy

-- | As `messageName`, but accepts message itself, may be more convinient is most cases.
messageName' :: Message m => m -> MessageName
messageName' = messageName . proxyOf

-- | From given conduit constructs a sink, which doesn't affect source above
-- (all readen data would be `leftover`ed).
intangibleSink :: MonadIO m => Conduit i m o -> Consumer i m (Maybe o)
intangibleSink cond = do
    taken <- liftIO $ newIORef []
    am <- notingCond taken =$= ignoreLeftovers =$= cond =$= CL.head
    forM am $ \a -> do
        mapM_ leftover =<< liftIO (readIORef taken)
        return a
  where
    notingCond taken = awaitForever $ \a -> do liftIO $ modifyIORef taken (a:)
                                               yield a
    ignoreLeftovers = awaitForever yield

-- | Like `conduitGet`, but applicable to be used inside `unpackMsg`.
conduitGet' :: MonadThrow m => Get b -> Conduit ByteString m b
conduitGet' g = start
  where
    start = do mx <- await
               case mx of
                  Nothing -> return ()
                  Just x -> do
                               go (runGetIncremental g `pushChunk` x)
    go (Done bs _ v) = do when (not $ BS.null bs) $ leftover bs
                          yield v
                          start
    go (Fail u o e)  = throwM (ParseError u o e)
    go (Partial n)   = await >>= (go . n)


-- * Serialization and deserialization

-- | Defines a way to serialize object @r@ with given packing type @p@.
class Packable p r where
    -- | Way of packing data to raw bytes. At the moment when value gets passed
    -- downstream, all unconsumed input should be `leftover`ed.
    packMsg :: MonadThrow m => p -> Conduit r m ByteString

-- | Defines a way to deserealize data with given packing type @p@ and extract object @r@.
class Unpackable p r where
    -- | Way of unpacking raw bytes to data.
    unpackMsg :: MonadThrow m => p -> Conduit ByteString m r


-- * Basic packing types

-- ** Binary

-- | Defines way to encode `Binary` instances into message of format
-- (header, [[name], content]), where [x] = (length of x, x).
-- /P/ here denotes to "packing".
data BinaryP = BinaryP

instance (Binary h, Binary r, Message r)
       => Packable BinaryP (HeaderNContentData h r) where
    packMsg p = CL.map packToRaw =$= packMsg p
      where
        packToRaw (HeaderNContentData h r) =
            HeaderNRawData h . RawData . BL.toStrict . runPut $ do
                put $ messageName $ proxyOf r
                put r

instance Binary h
      => Packable BinaryP (HeaderNRawData h) where
    packMsg _ = CL.map doPut =$= conduitPut
      where
        doPut (HeaderNRawData h (RawData r)) = put h >> put r

instance Binary h
      => Unpackable BinaryP (HeaderData h) where
    unpackMsg _ = conduitGet' $ HeaderData <$> get

instance Binary h
      => Unpackable BinaryP (HeaderNRawData h) where
    unpackMsg _ = conduitGet' $ HeaderNRawData <$> get <*> (RawData <$> get)

-- | TODO: don't read whole content
instance Binary h
      => Unpackable BinaryP (HeaderNNameData h) where
    unpackMsg p = unpackMsg p =$= CL.map extract
      where
        extract (HeaderNRawData h (RawData raw)) =
            runGet (HeaderNNameData h <$> get) $ BL.fromStrict raw

instance (Binary h, Binary r)
       => Unpackable BinaryP (HeaderNNameNContentData h r) where
    unpackMsg p = unpackMsg p =$= CL.map extract
      where
        extract (HeaderNRawData h (RawData raw)) =
            runGet (HeaderNNameNContentData h <$> get <*> get) $ BL.fromStrict raw

instance (Binary h, Binary r)
       => Unpackable BinaryP (HeaderNContentData h r) where
    unpackMsg p = unpackMsg p =$= CL.map extract
      where
        extract (HeaderNNameNContentData h _ r) = HeaderNContentData h r
