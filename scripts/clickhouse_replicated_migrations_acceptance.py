#!/usr/bin/env python3
"""Owned two-replica fixture bridge. No ambient ClickHouse or PostgreSQL targets."""
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid
from isolated_postgres import isolated_postgres
from clickhouse_migrations_acceptance import FaultProxy


def rpc(op, **values):
    print(json.dumps(dict(op=op, **values)), flush=True)
    return json.loads(sys.stdin.readline())


def rows(response):
    assert response['status'] == 200, response['body']
    return [json.loads(line) for line in response['body'].splitlines() if line.strip()]


def native_examples(env, fixture, root, replica):
    """Resolve only the exact owned fixture container, then verify native UUID."""
    import urllib.parse
    from test_support import binary, hspec
    context = os.environ['CLICKHOUSE_MIGRATE_DOCKER_CONTEXT']
    docker = ['docker','--context',context]
    port = urllib.parse.urlsplit(fixture['replicas'][0]['endpoint']).port
    containers = subprocess.check_output(docker+['ps','-q','--filter','label=clickhouse-migrate.fixture=owned'],text=True,timeout=10).split()
    assert containers, 'No owned fixture containers'
    inspected = json.loads(subprocess.check_output(docker+['inspect',*containers],text=True,timeout=10))
    selected = [c for c in inspected if any(int(p['HostPort'])==port for p in c['NetworkSettings']['Ports'].get('8123/tcp',[]) or [])]
    assert len(selected)==1, 'Native mapping must match exactly one owned HTTP endpoint'
    native = selected[0]['NetworkSettings']['Ports']['9000/tcp']
    assert len(native)==1
    test_env=dict(env,KANSOKU_CLICKHOUSE_USER='default',KANSOKU_REQUIRED_INTEGRATION='1',KANSOKU_CLICKHOUSE_HOST='127.0.0.1',CLICKHOUSE_TCP_PORT=native[0]['HostPort'])
    identity=subprocess.check_output(['clickhouse-client','--host','127.0.0.1','--port',native[0]['HostPort'],'--user','default','--password','test-password','--query','SELECT toString(serverUUID())'],env=test_env,text=True,timeout=10).strip()
    assert identity==rows(fixture['replicas'][0])[0]['id']
    patterns=['Kansoku.Query integration','Kansoku.Metrics.Limits/native','Kansoku.Metrics filters native','Kansoku.Enrichment native','Kansoku.Acquisition native','Kansoku.Activity native','Kansoku.Funnel native','Kansoku.Paths native','Kansoku.Traits native','Organization native','Kansoku.Sessions native','Kansoku.Session attributes native']
    count=0
    for index,pattern in enumerate(patterns):
        # Hspec writes diagnostics to stderr so stdout remains the fixture RPC protocol.
        import contextlib
        with contextlib.redirect_stdout(sys.stderr):
            count+=hspec([binary('kansoku-core:test:kansoku-core-test'),'--match='+pattern],env=test_env,log=root/f'query-{index}.private',timeout=300)
    for index in [0,1]:
        replica(index,'SYSTEM SYNC DATABASE REPLICA analytics')
    print(f'replicated native query/metrics: {count} examples, zero failures/pending',file=sys.stderr,flush=True)


def main():
    case = sys.argv[1]
    fixture = json.loads(sys.stdin.readline())
    root = Path(fixture['root']) / 'kansoku'
    root.mkdir(mode=0o700)
    direct = case == 'direct'
    ids = [fixture['replicas'][0][0]['id']] if direct else [rows(r)[0]['id'] for r in fixture['replicas']]
    native = os.environ['KANSOKU_CH_MIGRATION_BINARY']
    proof = os.environ['KANSOKU_CH_MIGRATION_PROOF_BINARY']
    pg_migrate = os.environ['KANSOKU_PG_MIGRATION_BINARY']
    with isolated_postgres(root / 'postgres') as env:
        sequence = 0
        def run(command, success=True, selected=None):
            nonlocal sequence
            sequence += 1
            result = subprocess.run(command, env=selected or env, capture_output=True, text=True, timeout=480)
            (root / f'command-{sequence}.private').write_text(result.stdout + result.stderr)
            assert (result.returncode == 0) == success, f'{case}: command {sequence} failed; evidence {root}'
            return json.loads(result.stdout) if result.stdout.strip().startswith('{') else result.stdout
        def pg(sql):
            return subprocess.check_output(['psql','-XAt','-v','ON_ERROR_STOP=1','-c',sql],env=env,text=True,timeout=10).strip()
        run([pg_migrate,'up'])
        endpoint = fixture['endpoint']
        if case == 'pinned':
            endpoint = fixture['replicas'][0]['endpoint']
        if case in ('missing-id','unexpected-id'):
            ids[1 if case == 'missing-id' else 0] = '00000000-0000-0000-0000-000000000000'
        env.update(KANSOKU_CH_MIGRATION_TARGET='kansoku/owned-' + uuid.uuid4().hex,
                   KANSOKU_CH_MIGRATION_ENDPOINT=endpoint,
                   KANSOKU_CH_MIGRATION_CLUSTER='fixture',
                   KANSOKU_CH_MIGRATION_REPLICA_IDS=','.join(ids),
                   KANSOKU_CH_MIGRATION_LEDGER_ID=str(uuid.uuid4()),
                   KANSOKU_CLICKHOUSE_USER='app',KANSOKU_CLICKHOUSE_PASSWORD='test-password')
        if direct:
            env.pop('KANSOKU_CH_MIGRATION_CLUSTER')
            env.pop('KANSOKU_CH_MIGRATION_REPLICA_IDS')
            env.update(KANSOKU_CH_MIGRATION_SERVER_ID=ids[0],KANSOKU_CLICKHOUSE_USER='default')
        proxy = FaultProxy(endpoint)
        env['KANSOKU_CH_MIGRATION_ENDPOINT'] = proxy.endpoint
        try:
            binary = proof if case == 'tiny' else native
            extra = ['--proof-tiny'] if case == 'tiny' else []
            def invoke(args, success=True, selected=None, executable=None):
                return run([executable or binary,*extra,*args],success,selected)
            def begin():
                report = invoke(['maintenance','begin','--json','--expect-target',env['KANSOKU_CH_MIGRATION_TARGET'],'--actor','owned proof','--reason',case])
                env['KANSOKU_CH_MIGRATION_SESSION'] = report['result']['id']
            def counter():
                return invoke(['maintenance','status','--json'])['result']['entry']
            def entry(args, success=True, executable=None):
                return invoke(['--predecessor',str(counter()),*args,'--json','--expect-target',env['KANSOKU_CH_MIGRATION_TARGET'],'--actor','owned proof','--reason','owned synchronous clients completed','--quiescent','--evidence',str(root)],success,executable=executable)
            begin()
            # Reordered inventory matches; changed identity refuses before native SQL.
            reordered = dict(env,KANSOKU_CH_MIGRATION_REPLICA_IDS=','.join(reversed(ids)))
            if not direct:
                invoke(['maintenance','status','--json'],selected=reordered)
                opposite={k:v for k,v in env.items() if k not in ('KANSOKU_CH_MIGRATION_CLUSTER','KANSOKU_CH_MIGRATION_REPLICA_IDS')}
                opposite['KANSOKU_CH_MIGRATION_SERVER_ID']=ids[0]
                invoke(['verify','--guarded','--json'],False,selected=opposite)
            for changed in ([] if direct else [dict(env,KANSOKU_CH_MIGRATION_CLUSTER='other'),dict(env,KANSOKU_CH_MIGRATION_REPLICA_IDS=ids[0] + ',33333333-3333-4333-8333-333333333333')]):
                invoke(['maintenance','status','--json'],False,selected=changed)
                invoke(['verify','--guarded','--json'],False,selected=changed)
                assert proxy.application_count() == 0
            if case == 'foreign-v1':
                direct_events=json.loads(Path('.dev/acceptance/direct-control-events.private').read_text())
                rpc('query',sql='CREATE TABLE kansoku_migration_ledger.events (sequence UInt64,event_id UUID,ledger_id UUID,event String) ENGINE=ReplicatedMergeTree ORDER BY (sequence,event_id)')
                rpc('query',sql='INSERT INTO kansoku_migration_ledger.events FORMAT JSONEachRow\n' + '\n'.join(json.dumps(row) for row in direct_events))
            if case == 'stopped':
                rpc('stop',index=1)
            success = case in ('tiny','direct','full')
            entry(['up','--initialize-ledger',env['KANSOKU_CH_MIGRATION_LEDGER_ID']],success)
            assert pg('SELECT count(*) FROM kansoku.maintenance_fence WHERE active_migration_session IS NOT NULL') == '1'
            if not success:
                assert proxy.application_count() == 0
                print(f'{case}: refused; fence retained; zero application requests',file=sys.stderr,flush=True)
                return
            invoke(['verify','--require-current','--guarded','--json'])
            status = invoke(['status','--json'])
            (root / 'status.json').write_text(json.dumps(status,indent=2))
            def replica(index, sql):
                return rpc('query',sql=sql) if direct else rows(rpc('replica',index=index,sql=sql))
            def events():
                return [replica(i,'SELECT * FROM kansoku_migration_ledger.events ORDER BY sequence') for i in ([0] if direct else [0,1])]
            # Re-initialization with matching ledger exercises interrupted recovery.
            entry(['up','--initialize-ledger',env['KANSOKU_CH_MIGRATION_LEDGER_ID']])
            before_events = events()
            if direct:
                Path('.dev/acceptance/direct-control-events.private').write_text(json.dumps(before_events[0]))
            assert before_events[0] and (direct or before_events[0] == before_events[1])
            assert ('sha256-v1' if direct else 'sha256-v2') in json.dumps(before_events)
            before = proxy.application_count()
            entry(['maintenance','finish'])
            assert pg('SELECT count(*) FROM kansoku.maintenance_fence WHERE active_migration_session IS NOT NULL') == '0'
            begin()
            entry(['up'])
            assert proxy.application_count() == before, 'Repeat submitted application SQL'
            assert events() == before_events, 'Repeat appended native events'
            invoke(['verify','--require-current','--guarded','--json'])
            entry(['maintenance','finish'])
            if case in ('direct','full'):
                schema_sql = "SELECT name,engine,sorting_key,primary_key,partition_key,create_table_query FROM system.tables WHERE database='analytics' ORDER BY name"
                snapshot = replica(0,schema_sql)
                parity_file = Path('.dev/acceptance/replicated-direct-control.private')
                if direct:
                    parity_file.write_text(json.dumps(snapshot))
                else:
                    import re
                    def normalized(items):
                        result=[]
                        for row in items:
                            row=dict(row)
                            row['engine']=row['engine'].removeprefix('Replicated')
                            sql=row['create_table_query']
                            sql=re.sub(r"Replicated(Aggregating|Replacing)MergeTree\('[^']*', '[^']*'(?:, )?",r'\1MergeTree(',sql)
                            sql=re.sub(r" UUID '[^']*'",'',sql)
                            sql=re.sub(r'\b(AggregatingMergeTree|ReplacingMergeTree)\(\)',r'\1',sql)
                            row['create_table_query']=sql
                            result.append(row)
                        return result
                    assert normalized(snapshot)==normalized(json.loads(parity_file.read_text())), 'Direct/replicated schema differs'
            if case == 'full':
                for i in [0,1]:
                    replica(i,'SYSTEM SYNC DATABASE REPLICA analytics')
                schema = "SELECT name,engine,engine_full,sorting_key,primary_key,partition_key,create_table_query FROM system.tables WHERE database='analytics' ORDER BY name"
                observations = [replica(i,schema) for i in ([0] if direct else [0,1])]
                assert len(observations[0]) > 0 and [r['name'] for r in observations[0]] == [r['name'] for r in observations[1]]
                assert not any(r['name'].startswith('__chm_legacy_assert_') for r in observations[0])
                (root / 'schema.private').write_text(json.dumps(observations,indent=2))
                for item in observations[0]:
                    if item['engine'].startswith('Replicated'):
                        assert replica(0,'SELECT count() AS n FROM analytics.`' + item['name'] + '`') == replica(1,'SELECT count() AS n FROM analytics.`' + item['name'] + '`')
                native_examples(env, fixture, root, replica)
                begin()
                entry(['up'],executable=proof)
                before = proxy.application_count()
                entry(['up'],executable=proof)
                assert proxy.application_count() == before
                invoke(['--proof-change-applied-step','--predecessor',str(counter()),'up','--json','--expect-target',env['KANSOKU_CH_MIGRATION_TARGET'],'--actor','owned proof','--reason','changed applied definition','--quiescent','--evidence',str(root)],False,executable=proof)
                assert proxy.application_count() == before
                entry(['maintenance','reconcile'],executable=proof)
                entry(['maintenance','finish'],executable=proof)
                for i in [0,1]:
                    assert replica(i,'SELECT id FROM analytics.__native_upgrade_probe') == [{'id':7}]
            print(f'{case}: lifecycle, guarded verify, recovery, repeat and finish passed; repeat application requests=0',file=sys.stderr,flush=True)
        finally:
            proxy.close()


if __name__ == '__main__':
    main()
