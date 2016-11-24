Time-warp: Library for emulating distributed systems.
---

Time-warp consists of 3 parts:
  1. `MonadTimed` library, which provides time (ala `threadDelay`) and
     threads (ala `forkIO`, `throwTo` and others) management capabilities.
  2. `MonadRpc` library, which provides network communication capabilities,
     [msgpack-rpc](https://hackage.haskell.org/package/msgpack-rpc-1.0.0)
     is taken as a foundation.

All these allow to write scenarios over distributed systems, which could be
launched either as real program or as fast emulation with manually controlled
network nastiness.
You can see examples in `Control.TimeWarp.Rpc` module.
