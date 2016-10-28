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
-- Maintainer  : Ivanov Kostia <martoon.391@gmail.com>
-- Stability   : experimental
-- Portability : POSIX, GHC
--
-- This module defines `Message` type, which binds a name to request.

module Control.TimeWarp.Rpc.Message
       ( Message (..)

       , Packable (..)
       , Unpackable (..)

       , BinaryP (..)
       , NamedBinaryP (..)
       , HeaderP (..)

       , ContentData (..)
       , NameData (..)
       , NameNContentData (..)
       , RawData (..)
       , HeaderData (..)
       , HeaderNRawData (..)

       , intangibleSink
       , proxyOf
       ) where

import           Control.Monad                     (forM, mapM_)
import           Control.Monad.Catch               (MonadThrow)
import           Control.Monad.Trans               (MonadIO (..))
import           Data.Binary                       (Binary (..), encode)
import           Data.ByteString                   (ByteString)
import qualified Data.ByteString.Char8             as BC
import qualified Data.ByteString.Lazy              as BL
import           Data.Conduit                      (Conduit, Consumer, awaitForever,
                                                    yield, (=$=), leftover)
import qualified Data.Conduit.List                 as CL
import           Data.Conduit.Serialization.Binary (conduitGet, conduitPut)
import           Data.Data                         (Data, dataTypeName, dataTypeOf)
import           Data.IORef                        (newIORef, readIORef,
                                                    modifyIORef)
import           Data.Proxy                        (Proxy (..), asProxyTypeOf)
import           Data.Typeable                     (Typeable)


type MessageName = ByteString

-- | Defines type which has it's uniqie name.
class Typeable m => Message m where
    -- | Uniquely identifies this type
    messageName :: Proxy m -> MessageName
    default messageName :: Data m => Proxy m -> MessageName
    messageName proxy =
        BC.pack . dataTypeName . dataTypeOf $ undefined `asProxyTypeOf` proxy


-- * Parts of message.
data ContentData r = ContentData r

-- | Designates data given from incoming message, but not deserialized to any specified
-- object.
data RawData = RawData ByteString

data NameData = NameData MessageName

data HeaderData h = HeaderData h

data HeaderNContentData h r = HeaderNContentData h r

data HeaderNRawData h = HeaderNRawData h ByteString

data NameNContentData r = NameNContentData MessageName r


-- * Util

proxyOf :: a -> Proxy a
proxyOf _ = Proxy

-- | From given conduit constructs consumer of single value,
-- which doesn't affect source above.
intangibleSink :: MonadIO m => Conduit i m o -> Consumer i m (Maybe o)
intangibleSink cond = do
    taken <- liftIO $ newIORef []
    am <- notingCond taken =$= cond =$= CL.head
    forM am $ \a -> do
        mapM_ leftover =<< liftIO (readIORef taken)
        return a
  where
    notingCond taken = awaitForever $ \a -> do liftIO $ modifyIORef taken (a:)
                                               yield a

-- * Typeclasses

-- | Defines a way to serialize object @r@ with given packing type @p@.
class Packable p r where
    -- | Way of packing data to raw bytes.
    packMsg :: MonadThrow m => p -> Conduit r m ByteString

class Unpackable p r where
    -- | Way of unpacking raw bytes to data.
    unpackMsg :: MonadThrow m => p -> Conduit ByteString m r


-- * Instances

-- ** Basic

-- | Defines way to encode `Binary` instances.
-- "P" here denotes to "packing".
data BinaryP = BinaryP

instance Binary r => Packable BinaryP (ContentData r) where
    packMsg _ = CL.map (\(ContentData d) -> put d) =$= conduitPut

instance Binary r => Unpackable BinaryP (ContentData r) where
    unpackMsg _ = conduitGet $ ContentData <$> get


-- | Defines pretty simple way to encode `Binary` instances: we just pack
-- @(methodName m, m)@ by means of `Binary`.
-- "N" here denotes to "named", "P" to "packing".
data NamedBinaryP = NamedBinaryP

instance (Binary r, Message r)
      => Packable NamedBinaryP (ContentData r) where
    packMsg _ = CL.map doPut =$= conduitPut
      where
        doPut (ContentData r) = do put $ messageName $ proxyOf r
                                   put r

instance Unpackable NamedBinaryP NameData where
    unpackMsg _ = conduitGet $ NameData <$> get

instance Binary r
      => Unpackable NamedBinaryP (NameNContentData r) where
    unpackMsg _ = conduitGet $ NameNContentData <$> get <*> get

instance Unpackable p (NameNContentData r)
      => Unpackable p (ContentData r) where
    unpackMsg p = unpackMsg p =$= CL.map (\(NameNContentData _ d) -> ContentData d)

-- | Defines way to encode `Binary` instances together with message header.
data HeaderP ph pr = HeaderP ph pr

instance (Packable ph h, Packable pr r) =>
          Packable (HeaderP ph pr) (HeaderNContentData h r) where
    packMsg (HeaderP ph pr) =
        awaitForever $ \(HeaderNContentData h r) ->
        do yield h =$= packMsg ph
           yield r =$= packMsg pr

instance (Unpackable ph h, Unpackable pr r) =>
          Unpackable (HeaderP ph pr) (HeaderNContentData h r) where
    unpackMsg (HeaderP ph pr) = do
        hm <- unpackMsg ph =$= CL.head
        rm <- unpackMsg pr =$= CL.head
        case (hm, rm) of
            (Just h, Just r) -> yield (HeaderNContentData h r)
            _                -> return ()

instance Unpackable ph h =>
         Unpackable (HeaderP ph pr) (HeaderData h) where
    unpackMsg (HeaderP ph _) = do
        hm <- unpackMsg ph =$= CL.head
        case hm of
            Nothing -> return ()
            Just h  -> yield $ HeaderData h


-- | Allows to take message as raw data by writing it's length at the beginning.
-- @n@ is packing type which supports `Int` packing.
data RawP p = RawP p

data RawContentData r = RawContentData r

-- | Instances here are implemented via Binary in hope, that `instance Binary ByteString`
-- does exactly what we want.
instance Packable (RawP p) RawData where
    packMsg _ = CL.map $ \(RawData raw) -> BL.toStrict $ encode raw

instance Packable p r => Packable (RawP p) (RawContentData r) where
    packMsg pr@(RawP p) = CL.map (\(RawContentData d) -> d)
                      =$= packMsg p
                      =$= CL.map RawData
                      =$= packMsg pr

instance Unpackable (RawP p) RawData where
    unpackMsg _ = conduitGet $ RawData <$> get

instance Unpackable p r => Unpackable (RawP p) (RawContentData r) where
    unpackMsg pr@(RawP p) = unpackMsg pr
                        =$= CL.map (\(RawData raw) -> raw)
                        =$= unpackMsg p
                        =$= CL.map RawContentData


-- * Misc

instance Message () where
    messageName _ = "()"
