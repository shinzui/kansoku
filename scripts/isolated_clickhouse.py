#!/usr/bin/env python3
"""Own an isolated ClickHouse instance and watchdog the required native cases."""
from contextlib import contextmanager
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


@contextmanager
def isolated_clickhouse(block_size=65536):
    tcp, http = free_port(), free_port()
    with tempfile.TemporaryDirectory(prefix='kansoku-native-') as directory:
        root = Path(directory)
        config = root / 'config.xml'
        config.write_text(f'''<clickhouse>
<path>{root}/data/</path><tmp_path>{root}/tmp/</tmp_path>
<tcp_port>{tcp}</tcp_port><http_port>{http}</http_port><listen_host>127.0.0.1</listen_host>
<logger><level>warning</level><log>{root}/server.log</log><errorlog>{root}/error.log</errorlog></logger>
<max_thread_pool_size>256</max_thread_pool_size>
<background_schedule_pool_size>8</background_schedule_pool_size>
<background_buffer_flush_schedule_pool_size>4</background_buffer_flush_schedule_pool_size>
<background_message_broker_schedule_pool_size>4</background_message_broker_schedule_pool_size>
<background_distributed_schedule_pool_size>4</background_distributed_schedule_pool_size>
<profiles><default><max_threads>4</max_threads><max_block_size>{block_size}</max_block_size></default></profiles>
<users><default><password></password><networks><ip>127.0.0.1</ip></networks><profile>default</profile><quota>default</quota></default></users>
<quotas><default/></quotas>
</clickhouse>''')
        with (root / 'console.log').open('w') as log:
            server = subprocess.Popen(['clickhouse-server', f'--config-file={config}'], cwd=root, stdout=log, stderr=log)
            try:
                client = ['clickhouse-client', '--host', '127.0.0.1', '--port', str(tcp)]
                for _ in range(100):
                    if server.poll() is not None:
                        raise RuntimeError((root / 'console.log').read_text())
                    ready = subprocess.run(client + ['--query', 'SELECT 1'], capture_output=True)
                    if ready.returncode == 0:
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError('isolated ClickHouse startup exceeded ten seconds')
                env = dict(os.environ, CLICKHOUSE_TCP_PORT=str(tcp), CLICKHOUSE_HTTP_PORT=str(http), KANSOKU_CLICKHOUSE_HOST='127.0.0.1', KANSOKU_CLICKHOUSE_DATABASE='analytics', KANSOKU_CLICKHOUSE_USER='default', KANSOKU_CLICKHOUSE_PASSWORD='', KANSOKU_REQUIRED_INTEGRATION='1')
                yield env
            finally:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


def apply_migrations(env):
    subprocess.run(['bash', 'db/clickhouse/migrate.sh'], env=env, check=True, timeout=120)
