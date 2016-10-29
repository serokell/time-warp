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
       ( MessageName
       , Message (..)

       , Packable (..)
       , Unpackable (..)

       , BinaryP (..)

       , ContentData (..)
       , NameData (..)
       , NameNContentData (..)
       , RawData (..)
       , HeaderData (..)
       , HeaderNNameData (..)
       , HeaderNRawData (..)
       , HeaderNContentData (..)
       , HeaderNNameNContentData (..)

       , intangibleSink
       , proxyOf

       , Empty (..)
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
import           Data.Typeable                     (Typeable)


type MessageName = T.Text

-- | Defines type which has it's uniqie name.
class Typeable m => Message m where
    -- | Uniquely identifies this type
    messageName :: Proxy m -> MessageName
    default messageName :: Data m => Proxy m -> MessageName
    messageName proxy =
         T.pack . dataTypeName . dataTypeOf $ undefined `asProxyTypeOf` proxy


-- * Parts of message.
data ContentData r = ContentData r

-- | Designates data given from incoming message, but not deserialized to any specified
-- object.
data RawData = RawData ByteString

data NameData = NameData MessageName

data HeaderData h = HeaderData h

data HeaderNContentData h r = HeaderNContentData h r

data HeaderNRawData h = HeaderNRawData h RawData

data HeaderNNameData h = HeaderNNameData h MessageName

data NameNContentData r = NameNContentData MessageName r

data HeaderNNameNContentData h r = HeaderNNameNContentData h MessageName r


-- * Util

proxyOf :: a -> Proxy a
proxyOf _ = Proxy

-- | From given conduit constructs consumer of single value,
-- which doesn't affect source above.
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


-- * Typeclasses

-- | Defines a way to serialize object @r@ with given packing type @p@.
class Packable p r where
    -- | Way of packing data to raw bytes. At the moment when value gets passed
    -- downstream, all unconsumed input should be `leftover`ed.
    packMsg :: MonadThrow m => p -> Conduit r m ByteString

class Unpackable p r where
    -- | Way of unpacking raw bytes to data.
    unpackMsg :: MonadThrow m => p -> Conduit ByteString m r


-- * Instances

-- ** Basic

-- | Defines way to encode `Binary` instances into message of format
-- (header, [[name], content]), where [x] = (length of x, x).
-- "P" here denotes to "packing".
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


-- * Empty object

data Empty = Empty

instance Binary Empty where
    get = return Empty
    put _ = return ()


-- * Misc

instance Message () where
    messageName _ = "()"
