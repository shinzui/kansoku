# Kansoku connection-lifetime compatibility repair

Source: `mori://KovalevDima/ClickHaskell/packages/ClickHaskell`, upstream
v1.1.0, revision `4524fbdd08cd0cf4a3468180323cbf6c4cf5667b` (library directory).
Hackage preferred versions and upstream tags checked 2026-10-15: 1.1.0 is current.
Cabal and Nix consume this same checked-in source.

The only code changes are in `ClickHaskell.hs` and `ClickHaskell/Connection.hs`:

- Close the socket when initial authentication fails or is cancelled.
- Invalidate and close a connection on operation failure; never reconnect while
  unwinding an exception. Later use of that handle raises `ConnectionClosed`.
- Export idempotent `closeConnection` so pool disposal releases physical sockets.

Connection owners open a fresh handle after failure. Kansoku's query pool and
writer already own that decision. No protocol, serialization or query changes
are included. Retain this repair until a released driver provides these lifecycle
operations, then run the native query-pool regression suite before removing it.
