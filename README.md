# Time-warp

Time-warp is a library for emulating distributed systems.

Scenarios written with the provided primitives can be launched in one of two modes.

  * Real mode refers to production environment with the use of IO threads and networking.
  * Emulation mode negotiates all delays introduced by a programmer with an analogy of
`threadDelay` function, remaining execution of different threads interleaving.
Networking is also emulated, providing full control over delays and packet losses induced by it.
This all allows for writing fast scenarios for system-wide testing.

You can see examples in dedicated [directory](/examples).

Time-warp consists of 3 parts:
  *  Auxilary logging library, which is a wrapper over
     [hslogger](http://hackage.haskell.org/package/hslogger) but allows
     to keep logger name into monadic context, making logging less boilerplate.
     Output is colored :star:.
  *  `MonadTimed` library, which provides time (ala `threadDelay`) and
     threads (ala `forkIO`, `throwTo` and others) management capabilities.
  *  `MonadRpc` library, which provides network communication capabilities,
     [msgpack-rpc](https://hackage.haskell.org/package/msgpack-rpc-1.0.0)
     is taken as a foundation.

## Build instructions [↑](#time-warp)

Run `stack build` to build everything.

## Usage [↑](#time-warp)

See [examples](/examples).

## Issue tracker [↑](#time-warp)

We use [YouTrack](https://issues.serokell.io/issues/TW) as our issue
tracker. You can login using your GitHub account to leave a comment or
create a new issue.

## For Contributors [↑](#time-warp)

Please see [CONTRIBUTING.md](/.github/CONTRIBUTING.md) for more information.

## About Serokell [↑](#time-warp)

Time-warp is maintained by [Serokell](https://serokell.io/).

We love open source software.
See which [services](https://serokell.io/#services) we provide and [drop us a line](mailto:hi@serokell.io) if you are interested.
