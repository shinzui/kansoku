"""Owned Apple Container bridge for the exact qualified Linux replica image.

Only containers created by this context are stopped. Failed evidence is retained;
no ambient Docker context, image substitution, or skipped cases are permitted.
"""
from contextlib import contextmanager
import base64
import http.client
import json
import os
import signal
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import time
import urllib.parse
import uuid
from isolated_clickhouse import free_port

IMAGE = 'docker.io/altinity/clickhouse-server@sha256:7e72405bf85df6d163205ee2e56251ebc35daf6dc71142f58bdee7a461690ffb'
VERSION = '26.3.60.10002.altinitystable'


def container(*args):
    return subprocess.check_output(['container', *args], text=True, stderr=subprocess.PIPE, timeout=90)


class RoundRobin:
    def __init__(self, ports):
        self.index = 0
        self.lock = threading.Lock()
        owner = self
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                import socket
                import select
                with owner.lock:
                    port = ports[owner.index % len(ports)]
                    owner.index += 1
                with socket.create_connection(('127.0.0.1', port), timeout=5) as peer:
                    while True:
                        ready, _, _ = select.select([self.request, peer], [], [], 1)
                        for source in ready:
                            data = source.recv(65536)
                            if not data:
                                return
                            (peer if source is self.request else self.request).sendall(data)
        class Server(socketserver.ThreadingTCPServer):
            daemon_threads = True
            allow_reuse_address = True
        self.server = Server(('127.0.0.1', 0), Handler)
        self.endpoint = 'http://127.0.0.1:' + str(self.server.server_address[1])
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


@contextmanager
def fixture(direct=False, cluster_name="fixture"):
    parent = Path('.dev/acceptance').resolve()
    parent.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='apple-clickhouse-', dir=parent))
    names, servers, logs = [], [], []
    network = 'kansoku-owned-' + uuid.uuid4().hex[:12]
    proxy = None
    def launch(label, memory):
        name = network + '-' + label
        path = root / label
        path.mkdir()
        http, native, keeper_port = free_port(), free_port(), free_port()
        container('run', '-d', '--name', name, '--arch', 'arm64', '--network', network,
                  '--label', 'kansoku.fixture=owned', '--cpus', '2', '--memory', memory,
                  '-v', str(path) + ':/fixture', '-p', f'127.0.0.1:{http}:8123', '-p', f'127.0.0.1:{native}:9000',
                  *(['-p',f'127.0.0.1:{keeper_port}:9181'] if label=='keeper' else []),
                  '--entrypoint', '/bin/sh', IMAGE, '-c', 'exec sleep 2147483647')
        names.append(name)
        inspected = json.loads(container('inspect', name))[0]
        (path/'container.private.json').write_text(json.dumps(inspected,indent=2))
        ip = inspected['status']['networks'][0]['ipv4Address'].split('/')[0]
        return dict(name=name, path=path, ip=ip, http=http, native=native, keeper_port=keeper_port)
    def start(server, mode='server'):
        log = (server['path'] / 'console.log').open('a')
        logs.append(log)
        process = subprocess.Popen(['container','exec',server['name'],'/bin/sh','-c',f'echo $$ > /fixture/server.pid; exec clickhouse {mode} --config-file=/fixture/config.xml'],stdout=log,stderr=log)
        servers.append(process)
        server['process'] = process
    def request(index, sql, user='default'):
        target = replicas[index]
        settings = dict(default_format='JSONEachRow',wait_end_of_query=1,async_insert=0,mutations_sync=2,alter_sync=2,fsync_metadata=1,max_result_rows=0,max_result_bytes=0,result_overflow_mode='throw',read_overflow_mode='throw',distributed_ddl_task_timeout=10,replication_wait_for_inactive_replica_timeout=10,insert_quorum_timeout=10000,insert_quorum=(0 if direct else 2),insert_quorum_parallel=0)
        connection = http.client.HTTPConnection('127.0.0.1', target['http'], timeout=60)
        try:
            auth = 'Basic ' + base64.b64encode((user+':test-password').encode()).decode()
            connection.request('POST','/?'+urllib.parse.urlencode(settings),sql.encode(),{'Authorization':auth})
            response = connection.getresponse()
            return dict(endpoint='http://127.0.0.1:'+str(target['http']),status=response.status,body=response.read().decode())
        finally:
            connection.close()
    def query(index, sql):
        result = request(index, sql)
        assert result['status'] == 200, result['body']
        return [json.loads(line) for line in result['body'].splitlines() if line.strip()]
    try:
        container('network', 'create', network)
        keeper = None if direct else launch('keeper', '512m')
        replicas = [launch('r'+str(i+1), '4g') for i in range(1 if direct else 2)]
        if keeper:
            (keeper['path'] / 'config.xml').write_text('''<clickhouse><logger><level>warning</level><console>true</console></logger><listen_host>0.0.0.0</listen_host>
<keeper_server><tcp_port>9181</tcp_port><server_id>1</server_id><log_storage_path>/fixture/log</log_storage_path><snapshot_storage_path>/fixture/snapshots</snapshot_storage_path><coordination_settings><operation_timeout_ms>10000</operation_timeout_ms><session_timeout_ms>10000</session_timeout_ms></coordination_settings><raft_configuration><server><id>1</id><hostname>localhost</hostname><port>9234</port></server></raft_configuration></keeper_server></clickhouse>''')
            start(keeper, 'keeper')
            # A server answering HTTP does not prove Keeper has elected a leader.
            import socket
            deadline = time.monotonic()+30
            while True:
                try:
                    with socket.create_connection(('127.0.0.1',keeper['keeper_port']),timeout=.5) as peer:
                        peer.sendall(b'ruok')
                        if peer.recv(4)==b'imok':
                            break
                except OSError:
                    pass
                if keeper['process'].poll() is not None or time.monotonic()>deadline:
                    raise RuntimeError('Owned Keeper readiness failed; evidence '+str(root))
                time.sleep(.1)
        cluster = '<remote_servers><'+cluster_name+'><shard>'+''.join(f'<replica><host>{r["ip"]}</host><port>9000</port><user>default</user><password>test-password</password></replica>' for r in replicas)+'</shard></'+cluster_name+'></remote_servers>'
        for i, server in enumerate(replicas):
            extra = '' if direct else cluster+f'<zookeeper><node><host>{keeper["ip"]}</host><port>9181</port></node></zookeeper><macros><cluster>{cluster_name}</cluster><shard>1</shard><replica>r{i+1}</replica></macros><interserver_http_port>9009</interserver_http_port><interserver_http_host>{server["ip"]}</interserver_http_host><distributed_ddl><path>/clickhouse/task_queue/ddl</path></distributed_ddl>'
            (server['path'] / 'users.xml').write_text('''<clickhouse><profiles><default><max_threads>2</max_threads><async_insert>1</async_insert><wait_for_async_insert>0</wait_for_async_insert><async_insert_busy_timeout_ms>10000</async_insert_busy_timeout_ms><mutations_sync>0</mutations_sync><alter_sync>0</alter_sync><fsync_metadata>0</fsync_metadata><max_result_rows>1</max_result_rows><result_overflow_mode>break</result_overflow_mode><max_block_size>1</max_block_size></default></profiles><users><default><password>test-password</password><networks><ip>::/0</ip></networks><profile>default</profile><quota>default</quota><access_management>1</access_management></default></users><quotas><default/></quotas></clickhouse>''')
            (server['path'] / 'config.xml').write_text(f'''<clickhouse><timezone>UTC</timezone><logger><level>warning</level><log>/fixture/server.log</log><errorlog>/fixture/error.log</errorlog></logger><path>/fixture/data/</path><tmp_path>/fixture/tmp/</tmp_path><access_control_path>/fixture/access/</access_control_path><users_config>/fixture/users.xml</users_config><listen_host>0.0.0.0</listen_host><http_port>8123</http_port><tcp_port>9000</tcp_port><max_connections>128</max_connections><max_thread_pool_size>1024</max_thread_pool_size><background_schedule_pool_size>64</background_schedule_pool_size><background_buffer_flush_schedule_pool_size>2</background_buffer_flush_schedule_pool_size><background_message_broker_schedule_pool_size>2</background_message_broker_schedule_pool_size><background_distributed_schedule_pool_size>2</background_distributed_schedule_pool_size><background_pool_size>16</background_pool_size><background_move_pool_size>2</background_move_pool_size><background_fetches_pool_size>2</background_fetches_pool_size><background_common_pool_size>2</background_common_pool_size><mark_cache_size>0</mark_cache_size><uncompressed_cache_size>0</uncompressed_cache_size>{extra}</clickhouse>''')
            start(server)
            deadline = time.monotonic()+60
            while True:
                try:
                    rows = query(i, 'SELECT version() AS version')
                    assert rows == [dict(version=VERSION)], rows
                    break
                except (OSError, AssertionError, http.client.HTTPException):
                    if server['process'].poll() is not None or time.monotonic()>deadline:
                        raise RuntimeError('Apple Container readiness failed; evidence '+str(root))
                    time.sleep(.1)
            if not direct:
                query(i,"CREATE USER app IDENTIFIED WITH plaintext_password BY 'test-password' SETTINGS database_replicated_allow_only_replicated_engine = 1 CONST")
                query(i,'GRANT SELECT, INSERT, CREATE TABLE, CREATE VIEW, ALTER TABLE, DROP TABLE, DROP VIEW, TRUNCATE, SYSTEM SYNC REPLICA, SYSTEM SYNC DATABASE REPLICA, CLUSTER, REMOTE ON *.* TO app')
        proxy = RoundRobin([r['http'] for r in replicas])
        observations = [request(i,'SELECT toString(serverUUID()) AS id') for i in range(len(replicas))]
        data = dict(root=str(root), endpoint=proxy.endpoint, replicas=([query(0,'SELECT toString(serverUUID()) AS id'),None] if direct else observations), nativePorts=[r['native'] for r in replicas],cluster=cluster_name, engine='apple', containers=[dict(id=r['name'],image=IMAGE,imageReference=IMAGE,nativePort=r['native'],httpPort=r['http'],network=network) for r in replicas])
        (root / 'fixture.private.json').write_text(json.dumps(data,indent=2))
        class Lifecycle:
            def __call__(self, index):
                server = replicas[index]
                if server['process'].poll() is not None:
                    raise RuntimeError('Owned replica already stopped')
                pid = (server['path'] / 'server.pid').read_text().strip()
                assert pid.isdigit() and int(pid) > 1, 'invalid owned server PID'
                container('exec', server['name'], 'kill', '-KILL', pid)
                server['process'].wait(timeout=15)

            def start(self, index):
                server = replicas[index]
                assert server['process'].poll() is not None, 'owned replica is still running'
                start(server)
                expected = (data['replicas'][0][0]['id'] if direct else json.loads(data['replicas'][index]['body'])['id'])
                deadline = time.monotonic() + 90
                while True:
                    try:
                        state = query(index, "SELECT toString(serverUUID()) AS id,(SELECT count() FROM system.database_replicas WHERE is_readonly) AS db_readonly,(SELECT count() FROM system.replicas WHERE database='analytics' AND is_readonly) AS table_readonly")[0]
                        assert state['id'] == expected, 'restored owned replica UUID changed'
                        if not state['db_readonly'] and not state['table_readonly']:
                            return
                    except (OSError, http.client.HTTPException, AssertionError):
                        pass
                    if server['process'].poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('Owned replica restart did not become writable; evidence '+str(root))
                    time.sleep(.2)
        yield data, query, request, Lifecycle()
    finally:
        if proxy:
            proxy.close()
        for name in reversed(names):
            try:
                container('stop', name)
                container('delete', name)
            except subprocess.CalledProcessError:
                pass
        for process in servers:
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
        for log in logs:
            log.close()
        try:
            container('network', 'delete', network)
        except subprocess.CalledProcessError:
            pass
        print('Apple Container fixture evidence: '+str(root), flush=True)


def run_bridge(command, data, query, request, lifecycle, timeout=900):
    """Run an owned line-RPC consumer with its exact child process group."""
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, start_new_session=True)
    def terminate():
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = threading.Timer(timeout, terminate)
    deadline.daemon = True
    deadline.start()
    try:
        process.stdin.write(json.dumps(data)+'\n')
        process.stdin.flush()
        for line in process.stdout:
            operation = json.loads(line)
            op = operation['op']
            if op == 'query':
                result = query(0, operation['sql'])
            elif op == 'replica':
                result = request(operation['index'], operation['sql'])
            elif op == 'stop':
                lifecycle(operation['index'])
                result = None
            elif op == 'start':
                lifecycle.start(operation['index'])
                result = None
            else:
                raise RuntimeError('unknown owned fixture operation: '+op)
            process.stdin.write(json.dumps(result)+'\n')
            process.stdin.flush()
        assert process.wait(timeout=30) == 0, 'owned runtime consumer failed'
    finally:
        deadline.cancel()
        if process.poll() is None:
            terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)


def main():
    import sys
    cases = sys.argv[1:] or ['tiny','direct','full','fresh','nonquorum','missing-id','unexpected-id','pinned','stopped','missing-ledger','atomic-ledger','missing-app','atomic-app','nonempty','foreign-v1']
    for case in cases:
        with fixture(case=='direct',cluster_name=('fixture-hyphen' if case=='hyphen' else 'fixture')) as (data, query, request, stop):
            if case!='direct':
                for db, omitted, atomic in [('analytics','missing-app','atomic-app'),('kansoku_migration_ledger','missing-ledger','atomic-ledger')]:
                    if case!=omitted:
                        engine = 'Atomic' if case==atomic else "Replicated('/clickhouse/databases/{uuid}', '{shard}', '{replica}')"
                        query(0,'CREATE DATABASE '+db+" ON CLUSTER '"+data['cluster']+"' ENGINE="+engine)
                if case=='nonempty':
                    query(0,'CREATE TABLE analytics.existing (id UInt8) ENGINE=ReplicatedMergeTree ORDER BY id')
            process = subprocess.Popen([sys.executable,'scripts/clickhouse_replicated_migrations_acceptance.py',case],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,start_new_session=True)
            def terminate_group():
                try:
                    os.killpg(process.pid,signal.SIGTERM)
                except ProcessLookupError:
                    pass
            # Preserve the former fixture bridge's fifteen-minute case budget.
            deadline=threading.Timer(900,terminate_group)
            deadline.daemon=True
            deadline.start()
            try:
                process.stdin.write(json.dumps(data)+'\n');process.stdin.flush()
                for line in process.stdout:
                    command=json.loads(line)
                    op=command['op']
                    if op=='query':result=query(0,command['sql'])
                    elif op=='replica':result=request(command['index'],command['sql'])
                    elif op=='stop':stop(command['index']);result=None
                    else:raise AssertionError('Unknown fixture operation')
                    process.stdin.write(json.dumps(result)+'\n');process.stdin.flush()
                code=process.wait(timeout=30)
                if code!=0:
                    replay=Path('kansoku-server/migrations/clickhouse-replicated/steps/0026_diagnostic_session_engagement/rebuild-sessions.sql').read_text()
                    canonical=replay.split('\nSETTINGS')[0].split('\n',1)[1]
                    for f in ['min','max','uniqExactIf','argMin','argMinIf','argMaxIf']:
                        canonical=canonical.replace(f+'State(',f+'(')
                    materialized='SELECT account_id,source_service,session_id,minMerge(started) AS started,maxMerge(ended) AS ended,uniqExactIfMerge(page_ids) AS page_ids,uniqExactIfMerge(engagement_ids) AS engagement_ids,argMinMerge(first_event) AS first_event,argMinIfMerge(first_page) AS first_page,argMaxIfMerge(last_page) AS last_page,maxMerge(bot) AS bot FROM analytics.sessions GROUP BY account_id,source_service,session_id'
                    evidence={}
                    for index in range(1 if case=='direct' else 2):
                        evidence[index]={}
                        for label,sql in [('canonical',canonical),('materialized',materialized),('retention','SELECT * FROM analytics.retention_policy FINAL'),('queues',"SELECT table,queue_size,log_max_index,log_pointer FROM system.replicas WHERE database='analytics'")]:
                            try:
                                evidence[index][label]=request(index,sql)
                            except (OSError,http.client.HTTPException) as error:
                                evidence[index][label]=dict(error=type(error).__name__)
                    (Path(data['root'])/'failed-session-state.private.json').write_text(json.dumps(evidence,indent=2))
                assert code==0, case+' failed; evidence '+data['root']
            finally:
                deadline.cancel()
                if process.poll() is None:
                    terminate_group()
                    try:
                        process.wait(timeout=20)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid,signal.SIGKILL)
                        process.wait(timeout=10)
    print(f'{len(cases)} owned Apple Container cases passed; zero failures; zero skipped')


if __name__=='__main__':
    main()
