# Time-warp

[![Build Status](https://travis-ci.org/serokell/time-warp.svg?branch=master)](https://travis-ci.org/serokell/time-warp)

Time-warp is a library for emulating distributed systems.

Time-warp consists of 2 parts:

* `MonadTimed` library, which provides time (ala `threadDelay`) and
threads (ala `forkIO`, `throwTo` and others) management capabilities.
* `MonadTransfer` & `MonadDialog`, which provide robust network layer,
allowing nodes to exchange messages utilizing user-defined serialization
strategy.

All these allow to write scenarios over distributed systems, which could be
launched either as real program or as fast emulation with manually controlled
network nastiness.

Work on emulation itself is yet WIP. For emulation support in old interface see
[version 0.3](../../tree/version-0.3).

## Build instructions [↑](#time-warp)

Run `stack build` to build everything.

## Usage [↑](#time-warp)

You can find examples in corresponding [directory](/examples).

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
