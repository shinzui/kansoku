"""Fast owned Nix ClickHouse/Keeper fixture for day-to-day runtime checks.

This Darwin 26.8 fixture is separate from exact Altinity Linux qualification.
Every process is started here and stopped through its retained Popen identity.
"""
from contextlib import contextmanager
import base64
import http.client
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import tempfile
import time
import urllib.parse

from apple_clickhouse_fixture import RoundRobin, run_bridge
from isolated_clickhouse import free_port

VERSION = '26.8.28.14'
IMAGE = 'nix-clickhouse-qualified-26.8.28.14-aarch64-darwin'


@contextmanager
def fixture(direct=False, cluster_name='fixture'):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise RuntimeError('Nix native fixture requires the qualified Darwin arm64 artifact')
    version = subprocess.check_output(['clickhouse-server','--version'], text=True).strip()
    assert VERSION in version, version
    parent = Path('.dev/acceptance').resolve()
    parent.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='nix-clickhouse-', dir=parent))
    processes, logs, proxy = [], [], None
    replicas = []
    def stop(server):
        process = server['process']
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
    def launch(server, mode='server'):
        log = (server['path'] / 'console.log').open('a')
        logs.append(log)
        process = subprocess.Popen(['clickhouse',mode,'--config-file='+str(server['path']/'config.xml')], cwd=server['path'], stdout=log, stderr=log)
        server['process'] = process
        (server['path']/'pid').write_text(str(process.pid))
        processes.append(server)
    def request(index, sql, user='default'):
        server = replicas[index]
        settings = dict(default_format='JSONEachRow',wait_end_of_query=1,async_insert=0,mutations_sync=2,alter_sync=2,fsync_metadata=1,max_result_rows=0,max_result_bytes=0,result_overflow_mode='throw',read_overflow_mode='throw',distributed_ddl_task_timeout=10,replication_wait_for_inactive_replica_timeout=10,insert_quorum_timeout=10000,insert_quorum=(0 if direct else 2),insert_quorum_parallel=0)
        connection = http.client.HTTPConnection('127.0.0.1',server['http'],timeout=60)
        try:
            auth = 'Basic '+base64.b64encode((user+':test-password').encode()).decode()
            connection.request('POST','/?'+urllib.parse.urlencode(settings),sql.encode(),{'Authorization':auth})
            response = connection.getresponse()
            return dict(endpoint='http://127.0.0.1:'+str(server['http']),status=response.status,body=response.read().decode())
        finally:
            connection.close()
    def query(index, sql):
        result = request(index,sql)
        assert result['status'] == 200, result['body']
        return [json.loads(line) for line in result['body'].splitlines() if line.strip()]
    def ready(index, expected=None):
        deadline = time.monotonic()+60
        while True:
            try:
                rows = query(index,"SELECT version() AS version,toString(serverUUID()) AS id,(SELECT value FROM system.server_settings WHERE name='path') AS data_root")
                assert rows[0]['version'] == VERSION
                assert Path(rows[0]['data_root']).resolve() == (replicas[index]['path']/'data').resolve(), 'refusing an unowned native endpoint'
                if expected:
                    assert rows[0]['id'] == expected, 'owned UUID changed'
                    state = query(index,"SELECT (SELECT count() FROM system.database_replicas WHERE is_readonly) AS db,(SELECT count() FROM system.replicas WHERE database='analytics' AND is_readonly) AS tables")[0]
                    if state['db'] or state['tables']:
                        raise OSError('owned replica recovering')
                return
            except (OSError, AssertionError, http.client.HTTPException):
                if replicas[index]['process'].poll() is not None or time.monotonic()>deadline:
                    raise RuntimeError('Owned Nix ClickHouse readiness failed; evidence '+str(root))
                time.sleep(.1)
    try:
        keeper_port = free_port()
        if not direct:
            path = root/'keeper'
            path.mkdir()
            raft = free_port()
            (path/'config.xml').write_text(f'''<clickhouse><logger><level>warning</level><console>true</console></logger><listen_host>127.0.0.1</listen_host><keeper_server><tcp_port>{keeper_port}</tcp_port><server_id>1</server_id><log_storage_path>{path}/log</log_storage_path><snapshot_storage_path>{path}/snapshots</snapshot_storage_path><coordination_settings><operation_timeout_ms>10000</operation_timeout_ms><session_timeout_ms>10000</session_timeout_ms></coordination_settings><raft_configuration><server><id>1</id><hostname>127.0.0.1</hostname><port>{raft}</port></server></raft_configuration></keeper_server></clickhouse>''')
            keeper = dict(path=path)
            launch(keeper, 'keeper')
            deadline = time.monotonic()+30
            while True:
                try:
                    with socket.create_connection(('127.0.0.1',keeper_port),timeout=.5) as peer:
                        peer.sendall(b'ruok')
                        if peer.recv(4) == b'imok':
                            break
                except OSError:
                    pass
                if keeper['process'].poll() is not None or time.monotonic()>deadline:
                    raise RuntimeError('Owned Nix Keeper startup failed; evidence '+str(root))
                time.sleep(.1)
        for i in range(1 if direct else 2):
            path = root/('r'+str(i+1))
            path.mkdir()
            replicas.append(dict(path=path,native=free_port(),http=free_port(),interserver=free_port()))
        cluster = '<remote_servers><'+cluster_name+'><shard>'+''.join(f'<replica><host>127.0.0.1</host><port>{r["native"]}</port><user>default</user><password>test-password</password></replica>' for r in replicas)+'</shard></'+cluster_name+'></remote_servers>'
        for i, server in enumerate(replicas):
            path = server['path']
            extra = '' if direct else cluster+f'<zookeeper><node><host>127.0.0.1</host><port>{keeper_port}</port></node></zookeeper><macros><cluster>{cluster_name}</cluster><shard>1</shard><replica>r{i+1}</replica></macros><interserver_http_port>{server["interserver"]}</interserver_http_port><interserver_http_host>127.0.0.1</interserver_http_host><distributed_ddl><path>/clickhouse/task_queue/ddl</path></distributed_ddl>'
            (path/'users.xml').write_text('''<clickhouse><profiles><default><max_threads>2</max_threads><async_insert>1</async_insert><wait_for_async_insert>0</wait_for_async_insert><max_result_rows>1</max_result_rows><result_overflow_mode>break</result_overflow_mode><max_block_size>1</max_block_size></default></profiles><users><default><password>test-password</password><networks><ip>127.0.0.1</ip></networks><profile>default</profile><quota>default</quota><access_management>1</access_management></default></users><quotas><default/></quotas></clickhouse>''')
            (path/'config.xml').write_text(f'''<clickhouse><timezone>UTC</timezone><logger><level>warning</level><log>{path}/server.log</log><errorlog>{path}/error.log</errorlog></logger><path>{path}/data/</path><tmp_path>{path}/tmp/</tmp_path><access_control_path>{path}/access/</access_control_path><users_config>{path}/users.xml</users_config><listen_host>127.0.0.1</listen_host><http_port>{server['http']}</http_port><tcp_port>{server['native']}</tcp_port><max_connections>128</max_connections><max_thread_pool_size>1024</max_thread_pool_size><background_schedule_pool_size>64</background_schedule_pool_size><background_buffer_flush_schedule_pool_size>2</background_buffer_flush_schedule_pool_size><background_message_broker_schedule_pool_size>2</background_message_broker_schedule_pool_size><background_distributed_schedule_pool_size>2</background_distributed_schedule_pool_size><background_pool_size>16</background_pool_size><background_move_pool_size>2</background_move_pool_size><background_fetches_pool_size>2</background_fetches_pool_size><background_common_pool_size>2</background_common_pool_size><mark_cache_size>0</mark_cache_size><uncompressed_cache_size>0</uncompressed_cache_size>{extra}</clickhouse>''')
            launch(server)
            ready(i)
            if not direct:
                query(i,"CREATE USER app IDENTIFIED WITH plaintext_password BY 'test-password' SETTINGS database_replicated_allow_only_replicated_engine = 1 CONST")
                query(i,'GRANT SELECT, INSERT, CREATE TABLE, CREATE VIEW, ALTER TABLE, DROP TABLE, DROP VIEW, TRUNCATE, SYSTEM SYNC REPLICA, SYSTEM SYNC DATABASE REPLICA, CLUSTER, REMOTE ON *.* TO app')
        proxy = RoundRobin([r['http'] for r in replicas])
        data = dict(root=str(root),endpoint=proxy.endpoint,replicas=[request(i,'SELECT toString(serverUUID()) AS id') for i in range(len(replicas))],nativePorts=[r['native'] for r in replicas],cluster=cluster_name,engine='nix',version=VERSION,processes=[dict(pid=r['process'].pid,root=str(r['path']),nativePort=r['native'],httpPort=r['http']) for r in replicas])
        (root/'fixture.private.json').write_text(json.dumps(data,indent=2))
        class Lifecycle:
            def __call__(self,index):
                assert replicas[index]['process'].poll() is None, 'owned replica already stopped'
                stop(replicas[index])
            def start(self,index):
                assert replicas[index]['process'].poll() is not None, 'owned replica still running'
                expected = json.loads(data['replicas'][index]['body'])['id']
                launch(replicas[index])
                ready(index,expected)
        yield data,query,request,Lifecycle()
    finally:
        if proxy:
            proxy.close()
        for server in reversed(processes):
            stop(server)
        for log in logs:
            log.close()
        print('Owned Nix ClickHouse fixture evidence: '+str(root),flush=True)


def main():
    """Use the same migration assertions with the fast owned native fixture."""
    import sys
    cases = sys.argv[1:] or ['tiny','direct','full','fresh','nonquorum','missing-id','unexpected-id','pinned','stopped','missing-ledger','atomic-ledger','missing-app','atomic-app','nonempty','foreign-v1']
    allowed = {'tiny','direct','full','fresh','nonquorum','missing-id','unexpected-id','pinned','stopped','missing-ledger','atomic-ledger','missing-app','atomic-app','nonempty','foreign-v1','hyphen'}
    if not cases or any(case not in allowed for case in cases):
        raise RuntimeError('Select nonzero known native migration cases')
    for case in cases:
        with fixture(case == 'direct', cluster_name=('fixture-hyphen' if case == 'hyphen' else 'fixture')) as (data, query, request, lifecycle):
            if case != 'direct':
                for database, omitted, atomic in [('analytics','missing-app','atomic-app'),('kansoku_migration_ledger','missing-ledger','atomic-ledger')]:
                    if case != omitted:
                        engine = 'Atomic' if case == atomic else "Replicated('/clickhouse/databases/{uuid}', '{shard}', '{replica}')"
                        query(0, 'CREATE DATABASE '+database+" ON CLUSTER '"+data['cluster']+"' ENGINE="+engine)
                if case == 'nonempty':
                    query(0, 'CREATE TABLE analytics.existing (id UInt8) ENGINE=ReplicatedMergeTree ORDER BY id')
            consumer = dict(data)
            if case == 'direct':
                consumer['replicas'] = [query(0, 'SELECT toString(serverUUID()) AS id'), None]
            run_bridge([sys.executable, 'scripts/clickhouse_replicated_migrations_acceptance.py', case], consumer, query, request, lifecycle)
    print(f'{len(cases)} owned Nix native cases passed; zero failures; zero skipped')


if __name__ == '__main__':
    main()
