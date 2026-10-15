# Kansoku connection-lifetime compatibility repair

Source: `mori://KovalevDima/ClickHaskell/packages/ClickHaskell`, upstream
v1.1.0, revision `4524fbdd08cd0cf4a3468180323cbf6c4cf5667b` (library directory).
Hackage preferred versions and upstream tags checked 2026-10-15: 1.1.0 is current.
Cabal and Nix consume this same checked-in source.

The compatibility changes touch `ClickHaskell.hs`, `ClickHaskell/Connection.hs` and
`ClickHaskell/Protocol/Client.hs`:

- Close the socket when initial authentication fails or is cancelled.
- Invalidate and close a connection on operation failure; never reconnect while
  unwinding an exception. Later use of that handle raises `ConnectionClosed`.
- Export idempotent `closeConnection` so pool disposal releases physical sockets.
- Consume Progress, ProfileInfo and ProfileEvents while commands and inserts finish;
  native CREATE-AS-SELECT/INSERT-SELECT emit these status packets.
- Correct QueryKind wire codes to 0/1/2. The upstream 1/2/3 encoding marks an
  InitialQuery as a secondary request, affecting analyzer and query-log behavior.
  Verified against `mori://ClickHouse/ClickHouse` (`src/Interpreters/ClientInfo.h`;
  registry/artifact-level URI coverage pending), the packaged engine's upstream v26.8.2.7-lts,
  commit c2930599c56702022276de06657ed51d83f31a05.

Connection owners open a fresh handle after failure. Kansoku's query pool and
writer already own that decision. Commands still reject data rows. Native progress/profile completion tests verify a
subsequent ping on the same socket, and the identity benchmark requires every
Haskell request to appear as an initial query in the native query log. Retain this repair until a released driver provides these lifecycle
operations, then run the native query-pool regression suite before removing it.
