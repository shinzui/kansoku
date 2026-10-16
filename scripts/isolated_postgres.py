"""A fresh, ownership-checked PostgreSQL process for destructive executable proofs."""
from contextlib import contextmanager
from pathlib import Path
import os
import subprocess
import tempfile
import time

from isolated_clickhouse import free_port


@contextmanager
def isolated_postgres(directory):
    root = Path(directory).resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('PG', 'CLICKHOUSE', 'KANSOKU_', 'OTEL_'))
           or key in ('KANSOKU_CH_MIGRATION_BINARY','KANSOKU_PG_MIGRATION_BINARY')}
    data = root / 'data'
    init = subprocess.run(['initdb', '-D', str(data), '-A', 'trust', '-U', 'postgres',
                           '--no-locale', '--encoding=UTF8'], env=env, capture_output=True, text=True)
    (root / 'init.private').write_text(init.stdout + init.stderr)
    init.check_returncode()
    with tempfile.TemporaryDirectory(prefix='ks-admin-pg-') as socket:
        port = free_port()
        env.update(PGHOST=socket, PGPORT=str(port), PGUSER='postgres', PGDATABASE='postgres',
                   PG_CONNECTION_STRING=f'host={socket} port={port} user=postgres dbname=postgres',
                   KANSOKU_OWNED_POSTGRES_ROOT=str(data.resolve()))
        with (root / 'server.private').open('w') as output:
            process = subprocess.Popen(['postgres', '-D', str(data), '-k', socket, '-p', str(port),
                                        '-h', '127.0.0.1'], env=env, stdout=output, stderr=output)
            (root / "pid").write_text(str(process.pid))
            try:
                for _ in range(100):
                    if process.poll() is not None:
                        raise RuntimeError('owned administrative PostgreSQL exited')
                    ready = subprocess.run(['pg_isready'], env=env, capture_output=True, timeout=3)
                    if ready.returncode == 0:
                        break
                    time.sleep(.1)
                else:
                    raise RuntimeError('owned administrative PostgreSQL startup timed out')
                actual = subprocess.check_output(['psql', '-XAtc', 'SHOW data_directory'], env=env, text=True).strip()
                assert actual == str(data), 'refusing administrative proof against unowned PostgreSQL'
                yield env
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
