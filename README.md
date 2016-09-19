Time-warp: Library for emulating distributed systems.
---

Time-warp consists of 3 parts:
  1. Auxilary logging library, which is wrapper over 
     [hslogger](http://hackage.haskell.org/package/hslogger) but allows
     to keep logger name into monadic context, making logging less boilerplate.
     Output is colored :star:
  2. `MonadTimed` library, which provides time (ala `threadDelay`) and 
     threads (ala `forkIO`, `throwTo` and others) management capabilities.
  3. `MonadRpc` library, which provides network communication probabilities,
     [msgpack-rpc](https://hackage.haskell.org/package/msgpack-rpc-1.0.0)
     is taken as a foundation.

All these allow to write scenarious over disctributed systems, which could be
launched either as real program or as fast emulation with manually controlled
network nastiness.
You can see examples in `Control.TimeWarp.Rpc` module.
