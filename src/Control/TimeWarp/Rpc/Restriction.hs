{-# LANGUAGE Rank2Types #-}

-- | This module helps abstragate from concrete instance of
-- `Control.TimeWarp.Rpc.MonadRpc`.
--
-- Consider such example:
--
-- @
-- sumMethod :: MonadRpc m => Int -> Int -> ServerT m Int
-- sumMethod a b = return $ a + b
--
-- startServer :: MonadRpc m => m ()
-- startServer = serve 1234 [method "sum" sumMethod]
-- @
--
-- This code won't compile, because compiler doesn't know that type @m@
-- in @sumMethod@ is the same @m@ as in @startServer@, so it can't apply
-- 'Control.TimeWarp.Rpc.MonadRpc.method' to @sumMethod@
-- (`Network.MessagePack.Server.MethodType` won't be deduced).
--
-- Functions @restrictServerType/N/@, where /N/ is method's arguments number,
-- help to bound the type. They are all defined like @return id@.
--
-- So the error above can be fixed in following way:
--
-- @
-- startServer :: MonadRpc m => m ()
-- startServer = do
--    idr <- restrictServerType2
--    serve 1234 [method "sum" $ idr sumMethod]
-- @

module Control.TimeWarp.Rpc.Restriction where

import Control.TimeWarp.Rpc.MonadRpc (ServerT)

type ServerRestriction m t = m (t -> t)

serverTypeRestriction0 ::
    Monad m => ServerRestriction m (ServerT m a)
serverTypeRestriction0 = return id

serverTypeRestriction1 ::
    Monad m => ServerRestriction m (b -> ServerT m a)
serverTypeRestriction1 = return id

serverTypeRestriction2 ::
    Monad m => ServerRestriction m (c -> b -> ServerT m a)
serverTypeRestriction2 = return id

serverTypeRestriction3 ::
    Monad m => ServerRestriction m (d -> c -> b -> ServerT m a)
serverTypeRestriction3 = return id

serverTypeRestriction4 ::
    Monad m => ServerRestriction m (e -> d -> c -> b -> ServerT m a)
serverTypeRestriction4 = return id

serverTypeRestriction5 ::
    Monad m => ServerRestriction m (f -> e -> d -> c -> b -> ServerT m a)
serverTypeRestriction5 = return id
