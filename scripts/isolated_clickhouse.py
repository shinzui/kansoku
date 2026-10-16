#!/usr/bin/env python3
"""Own an isolated ClickHouse instance and watchdog the required native cases."""
from contextlib import contextmanager
import os
import platform
import shutil
from pathlib import Path
import socket
import subprocess
import tempfile
import time


_OWNED_STACKS = {}

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


@contextmanager
def owned_clickhouse_root(directory):
    root = Path(directory).resolve() if directory is not None else Path(tempfile.mkdtemp(prefix='kansoku-native-')).resolve()
    success = False
    try:
        yield root
        success = True
    finally:
        if success and directory is None:
            shutil.rmtree(root)
        elif not success:
            print('Failed owned ClickHouse evidence retained: ' + str(root), flush=True)


@contextmanager
def isolated_clickhouse(block_size=65536, directory=None, query_logging=False, access_management=False, controller=None):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise RuntimeError('Native execution is unqualified on this platform; Linux qualification is unresolved and required cases cannot skip')
    version = subprocess.check_output(['clickhouse-server', '--version'], text=True)
    if '26.8.28.14' not in version:
        raise RuntimeError('Expected the qualified ClickHouse 26.8.28.14 artifact from the default Nix shell')
    tcp, http = free_port(), free_port()
    with owned_clickhouse_root(directory) as directory:
        root = Path(directory)
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        config = root / 'config.xml'
        access = '<access_management>1</access_management>' if access_management else ''
        access_storage = f'<access_control_path>{root}/access/</access_control_path>' if access_management else ''
        query_log = '<query_log><database>system</database><table>query_log</table><flush_interval_milliseconds>100</flush_interval_milliseconds></query_log>' if query_logging else ''
        config.write_text(f'''<clickhouse>
{query_log}
<path>{root}/data/</path>{access_storage}<tmp_path>{root}/tmp/</tmp_path>
<tcp_port>{tcp}</tcp_port><http_port>{http}</http_port><listen_host>127.0.0.1</listen_host>
<logger><level>warning</level><log>{root}/server.log</log><errorlog>{root}/error.log</errorlog></logger>
<max_thread_pool_size>256</max_thread_pool_size>
<background_schedule_pool_size>8</background_schedule_pool_size>
<background_buffer_flush_schedule_pool_size>4</background_buffer_flush_schedule_pool_size>
<background_message_broker_schedule_pool_size>4</background_message_broker_schedule_pool_size>
<background_distributed_schedule_pool_size>4</background_distributed_schedule_pool_size>
<profiles><default><max_threads>4</max_threads><max_block_size>{block_size}</max_block_size></default></profiles>
<users><default>{access}<password></password><networks><ip>127.0.0.1</ip></networks><profile>default</profile><quota>default</quota></default></users>
<quotas><default/></quotas>
</clickhouse>''')
        with (root / 'console.log').open('w') as log:
            client = ['clickhouse-client', '--host', '127.0.0.1', '--port', str(tcp)]
            def start():
                process = subprocess.Popen(['clickhouse-server', f'--config-file={config}'], cwd=root, stdout=log, stderr=log)
                (root / 'pid').write_text(str(process.pid))
                try:
                    deadline = time.monotonic() + 60
                    while time.monotonic() < deadline:
                        if process.poll() is not None:
                            raise RuntimeError('owned ClickHouse exited before readiness; private console retained')
                        ready = subprocess.run(client + ['--query', "SELECT value FROM system.server_settings WHERE name = 'path'"], capture_output=True, text=True, timeout=3)
                        if ready.returncode == 0 and ready.stdout.strip().rstrip('/') == str(root / 'data'):
                            return process
                        time.sleep(.1)
                    raise RuntimeError('owned ClickHouse startup deadline exceeded')
                except BaseException:
                    stop(process)
                    raise
            def stop(process):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=10)
            server = start()
            def restart():
                nonlocal server
                stop(server)
                server = start()
            owner = {'restart': restart}
            _OWNED_STACKS[str(root.resolve())] = owner
            if controller is not None:
                controller['restart'] = restart
            try:
                clean = {key:value for key,value in os.environ.items() if not key.startswith("KANSOKU_CH_MIGRATION_") or key == "KANSOKU_CH_MIGRATION_BINARY"}
                env = dict(clean, CLICKHOUSE_TCP_PORT=str(tcp), CLICKHOUSE_HTTP_PORT=str(http), KANSOKU_CLICKHOUSE_HOST='127.0.0.1', KANSOKU_CLICKHOUSE_DATABASE='analytics', KANSOKU_CLICKHOUSE_USER='default', KANSOKU_CLICKHOUSE_PASSWORD='', KANSOKU_REQUIRED_INTEGRATION='1', KANSOKU_OWNED_CLICKHOUSE_ROOT=str(root.resolve()))
                yield env
            finally:
                _OWNED_STACKS.pop(str(root.resolve()), None)
                stop(server)


def apply_migrations(env):
    root = env.get('KANSOKU_OWNED_CLICKHOUSE_ROOT')
    if root not in _OWNED_STACKS:
        raise RuntimeError('Migrations require a currently owned ClickHouse context; ambient endpoints are refused')
    from native_clickhouse_migrations import initialize_owned
    initialize_owned(env, _OWNED_STACKS[root])
