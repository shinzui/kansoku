"""Owned-test proxy: discard exactly one PostgreSQL COMMIT confirmation.

Connects only to the supplied private Unix socket. The first backend
CommandComplete(COMMIT) is consumed after the transaction commits, then both
sockets close before the client sees the result. Subsequent connections pass.
Protocol framing: https://www.postgresql.org/docs/current/protocol-message-formats.html
Never logs SQL, credentials, or message bodies.
"""

import asyncio
import struct
import sys


async def main(socket_path):
    dropped = False

    async def connection(client_reader, client_writer):
        nonlocal dropped
        server_writer = None
        tasks = []
        try:
            server_reader, server_writer = await asyncio.open_unix_connection(socket_path)

            async def upstream():
                while data := await client_reader.read(65536):
                    server_writer.write(data)
                    await server_writer.drain()

            async def downstream():
                nonlocal dropped
                while True:
                    header = await server_reader.readexactly(5)
                    size = struct.unpack("!I", header[1:])[0]
                    if size < 4 or size > 16 * 1024 * 1024:
                        raise ValueError("unexpected PostgreSQL frame size")
                    body = await server_reader.readexactly(size - 4)
                    if not dropped and header[:1] == b"C" and body == b"COMMIT\0":
                        dropped = True
                        print("dropped-commit", flush=True)
                        return
                    client_writer.write(header + body)
                    await client_writer.drain()

            tasks = [asyncio.create_task(upstream()), asyncio.create_task(downstream())]
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            client_writer.close()
            if server_writer:
                server_writer.close()
            await client_writer.wait_closed()
            if server_writer:
                await server_writer.wait_closed()

    server = await asyncio.start_server(connection, "127.0.0.1", 0)
    print(server.sockets[0].getsockname()[1], flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
