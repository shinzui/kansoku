#!/usr/bin/env python3
"""Private loopback fault proxy; a sentinel closes and refuses all connections."""
import asyncio
from pathlib import Path
import sys


async def main(upstream_port, sentinel):
    peers = set()

    async def connection(reader, writer):
        if sentinel.exists():
            writer.close()
            await writer.wait_closed()
            return
        upstream = None
        tasks = []
        peers.add(writer)
        try:
            upstream_reader, upstream = await asyncio.open_connection('127.0.0.1', upstream_port)
            peers.add(upstream)

            async def forward(source, target):
                while data := await source.read(65536):
                    target.write(data)
                    await target.drain()

            tasks = [asyncio.create_task(forward(reader, upstream)),
                     asyncio.create_task(forward(upstream_reader, writer))]
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        except (OSError, ConnectionError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            for peer in (writer, upstream):
                if peer is not None:
                    peers.discard(peer)
                    peer.close()
                    try:
                        await peer.wait_closed()
                    except ConnectionError:
                        pass

    async def watch():
        while True:
            if sentinel.exists():
                for peer in list(peers):
                    peer.close()
            await asyncio.sleep(.025)

    server = await asyncio.start_server(connection, '127.0.0.1', 0)
    print(server.sockets[0].getsockname()[1], flush=True)
    watcher = asyncio.create_task(watch())
    try:
        async with server:
            await server.serve_forever()
    finally:
        watcher.cancel()
        await asyncio.gather(watcher, return_exceptions=True)


if __name__ == '__main__':
    asyncio.run(main(int(sys.argv[1]), Path(sys.argv[2])))
