-- | This module provides RPC capabilities. It allows to write scenarious over
-- distributed systems, which can when be launched as either real program or
-- emulation with network nastiness manually controlled.
--
-- /Some interesting scenario here:/
--

module Control.TimeWarp.Rpc
       ( module Control.TimeWarp.Rpc.MonadRpc
       , module Control.TimeWarp.Rpc.MsgPackRpc
       , module Control.TimeWarp.Rpc.PureRpc
       ) where

import           Control.TimeWarp.Rpc.Arbitrary  ()
import           Control.TimeWarp.Rpc.MonadRpc
import           Control.TimeWarp.Rpc.MsgPackRpc
import           Control.TimeWarp.Rpc.PureRpc
