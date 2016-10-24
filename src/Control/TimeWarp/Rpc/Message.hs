{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DefaultSignatures     #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}

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
       , Serializable (..)
       , NamedPacking (..)
       , NamedSerializable
       , BinaryP (..)
       , NamedBinaryP (..)
       , NamedDefP (..)
       , Magic32P (..)
       , proxyOf
       ) where

import           Control.Applicative               ((<|>), many)
import           Control.Monad                     (forever)
import           Control.Monad.Catch               (MonadThrow)
import           Data.Binary                       (Binary (..), encode)
import           Data.Binary.Get                   (Decoder (..), Get, pushChunk,
                                                    runGetIncremental, lookAhead)
import           Data.ByteString                   (ByteString)
import qualified Data.ByteString                   as BS
import qualified Data.ByteString.Char8             as BC
import qualified Data.ByteString.Lazy              as BL
import           Data.Conduit                      (Conduit, yield, awaitForever,
                                                    leftover, (=$=), await, (=$), ($$))
import           Data.Conduit.List                 as CL
import           Data.Conduit.Serialization.Binary (sinkGet, sourcePut,
                                                    conduitPut)
import           Data.Data                         (Data, dataTypeName, dataTypeOf)
import           Data.Proxy                        (Proxy (..), asProxyTypeOf)
import qualified Data.Text                         as T
import           Data.Typeable                     (Typeable)
import           Data.Word                         (Word8, Word32)

-- | Defines type which has it's uniqie name.
class Message m where
    -- | Uniquely identifies this type
    messageName :: Proxy m -> ByteString
    default messageName :: Data m => Proxy m -> ByteString
    messageName proxy =
        BC.pack . dataTypeName . dataTypeOf $ undefined `asProxyTypeOf` proxy


-- * Util

proxyOf :: a -> Proxy a
proxyOf _ = Proxy

-- | Copy-paste of `conduitGet`, but which returns `Either`
conduitGetSafe :: Monad m => Get b -> Conduit ByteString m (Either T.Text b)
conduitGetSafe g = start
  where
    start = do mx <- await
               case mx of
                  Nothing -> return ()
                  Just x -> go (runGetIncremental g `pushChunk` x)
    go (Done bs _ v) = do yield $ Right v
                          if BS.null bs
                            then start
                            else go (runGetIncremental g `pushChunk` bs)
    go (Fail _ _ e)  = yield $ Left $ T.pack e
    go (Partial n)   = await >>= (go . n)


-- * Typeclasses

-- | Defines a way to serialize object @r@ with given packing type @p@.
-- TODO: eliminate MonadThrow
class Typeable r => Serializable p r where
    -- | Way of packing data to raw bytes.
    -- Note, that each bytestring at output should correspond to exactly
    -- single message of input.
    packMsg :: MonadThrow m => p -> Conduit r m ByteString

    -- | Way of unpacking raw bytes to data.
    -- If parse error occured, @Left errorMessage@ should be yielded, and
    -- then parsing should continue from some point ahead.
    unpackMsg :: MonadThrow m => p -> Conduit ByteString m (Either T.Text r)

-- | Defines a way to extract a message name from serialized data.
class NamedPacking p where
    -- | Peeks name of incoming message, without consuming any input.
    lookMsgName :: MonadThrow m => p -> Conduit ByteString m (Either T.Text ByteString)

type NamedSerializable p r = (Serializable p r, NamedPacking p, Message r)


-- * Instances

-- ** Basic

-- | Defines pretty simple way to encode `Binary` instances: we just pack
-- @(methodName m, m)@ by means of `Binary`.
data NamedBinaryP = NamedBinaryP

instance (Binary r, Typeable r, Message r) => Serializable NamedBinaryP r where
    packMsg _ = let putSingle m = put (messageName $ proxyOf m, m)
                in  CL.map putSingle =$= conduitPut

    unpackMsg _ = conduitGetSafe (bsFirst <$> get) =$= CL.map (fmap snd)
      where
        bsFirst :: (ByteString, r) -> (ByteString, r)
        bsFirst = id


instance NamedPacking NamedBinaryP where
    lookMsgName _ = conduitGetSafe (lookAhead get :: Get (ByteString, Any)) =$= CL.map (fmap fst)


-- | Can be anything in serialized form.
data Any = Any

instance Binary Any where
    get = Any <$ many (get :: Get Word8)
    put _ = return ()

-- ** Lego
-- Allows to combine different packing primitive modifiers, like adding magic constant or
-- hash.
-- TODO: doesn't work yet

-- | Packs instances of `Binary`.
data BinaryP = BinaryP

instance (Binary r, Typeable r) => Serializable BinaryP r where
    packMsg _ = CL.map put =$= conduitPut
    unpackMsg _ = conduitGetSafe get


-- | Takes instance of `Message`, packed in any way, and adds `methodName` into packing.
data NamedDefP p = NamedDefP p

instance (Serializable p r, Message r) => Serializable (NamedDefP p) r where
    packMsg (NamedDefP p) =
        awaitForever $
        \m -> do
            sourcePut $ put (messageName $ proxyOf m)
            Just encoded <- yield m =$ packMsg p $$ CL.head
            sourcePut $ put encoded

    unpackMsg (NamedDefP p) = forever $ do
        mname <- sinkGet $ Just <$> (get :: Get ByteString)
                       <|> pure Nothing
        case mname of
            Nothing -> yield $ Left "Failed to get message name"
            Just _  -> do
                msgM <- unpackMsg p =$ CL.head
                case msgM of
                    Nothing          -> yield $ Left "Unexpected end of input"
                    Just (Right msg) -> yield $ Right msg
                    Just err         -> yield err

instance NamedPacking (NamedDefP a) where
    lookMsgName _ = forever $ do
        nameM <- sinkGet . lookAhead $ Just <$> (get :: Get ByteString)
                                   <|> pure Nothing
        case nameM of
            Nothing   -> yield $ Left "Failed to get message name"
            Just name -> yield $ Right name

-- | Adds constant prefix to packed message. Helps to separate messages, and
-- find next intact message in case of stream gets dirty.
data Magic32P a = Magic32P Word32 a

instance Serializable p r => Serializable (Magic32P p) r where
    packMsg (Magic32P magic p) =
        awaitForever $
        \m -> do
            sourcePut $ put magic
            yield m =$= packMsg p

    unpackMsg (Magic32P magic p) = forever $ do
        w <- sinkGet $ Just <$> get
                   <|> pure Nothing
        case w of
            Nothing -> return ()  -- input ended
            Just m  ->
                if m /= magic
                    then yield $ Left "Magic constant doesn't match"
                    else do
                        msgM <- unpackMsg p =$ CL.head
                        case msgM of
                            Nothing          -> yield $ Left "Unexpected end of input"
                            Just (Right msg) -> yield $ Right msg
                            Just err         -> yield err

instance NamedPacking p => NamedPacking (Magic32P p) where
    lookMsgName (Magic32P magic p) = forever $ do
        w <- sinkGet $ Just <$> get
                   <|> pure Nothing
        case w of
            Nothing -> return ()  -- input ended
            Just m  -> if m == magic
                          then lookMsgName p >> leftover (BL.toStrict $ encode w)
                          else yield $ Left "Magic constant doesn't match"


-- * Misc

instance Message () where
    messageName _ = "()"
