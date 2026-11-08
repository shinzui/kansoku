#!/usr/bin/env python3
"""Owned two-replica fixture bridge. No ambient ClickHouse or PostgreSQL targets."""
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid
from isolated_postgres import isolated_postgres
from clickhouse_migrations_acceptance import FaultProxy, parity_observation


def rpc(op, **values):
    print(json.dumps(dict(op=op, **values)), file=sys.__stdout__, flush=True)
    return json.loads(sys.stdin.readline())


def rows(response):
    assert response['status'] == 200, response['body']
    return [json.loads(line) for line in response['body'].splitlines() if line.strip()]


def native_examples(env, fixture, root, replica):
    """Resolve only the exact owned fixture container, then verify native UUID."""
    import urllib.parse
    from test_support import binary, hspec
    native_port = str(fixture['nativePorts'][0])
    test_env=dict(env,KANSOKU_CLICKHOUSE_USER='kansoku_native_tests',KANSOKU_REQUIRED_INTEGRATION='1',KANSOKU_QUERY_LIMIT_FIXTURES='1',KANSOKU_CLICKHOUSE_HOST='127.0.0.1',CLICKHOUSE_TCP_PORT=native_port)
    identity=subprocess.check_output(['clickhouse-client','--host','127.0.0.1','--port',native_port,'--user','default','--password','test-password','--query','SELECT toString(serverUUID())'],env=test_env,text=True,timeout=10).strip()
    assert identity==rows(fixture['replicas'][0])[0]['id']
    patterns=['Kansoku.Query integration','Kansoku.Metrics.Limits/native','Kansoku.Metrics filters native','Kansoku.Enrichment native','Kansoku.Acquisition native','Kansoku.Activity native','Kansoku.Funnel native','Kansoku.Paths native','Kansoku.Traits native','Organization native','Kansoku.Sessions native','Kansoku.Session attributes native']
    for index in [0,1]:
        replica(index,"CREATE USER kansoku_native_tests IDENTIFIED WITH plaintext_password BY 'test-password' SETTINGS insert_deduplicate=0,async_insert=0,wait_for_async_insert=1,mutations_sync=2,alter_sync=2,max_result_rows=0,max_result_bytes=0,result_overflow_mode='throw',read_overflow_mode='throw',distributed_ddl_output_mode='none'")
        replica(index,'GRANT SELECT, INSERT, CREATE TABLE, CREATE VIEW, CREATE TEMPORARY TABLE, ALTER TABLE, DROP TABLE, DROP VIEW, TRUNCATE, OPTIMIZE, SYSTEM, KILL QUERY ON *.* TO kansoku_native_tests')
    effective=json.loads(subprocess.check_output(['clickhouse-client','--host','127.0.0.1','--port',native_port,'--user','kansoku_native_tests','--password','test-password','--query',"SELECT currentUser() AS user,getSetting('insert_deduplicate') AS dedup,getSetting('async_insert') AS async FORMAT JSONEachRow"],env=test_env,text=True,timeout=10))
    assert effective=={'user':'kansoku_native_tests','dedup':False,'async':False}, effective
    # Destructive fixture reseeding must not be mistaken for a retried insert.
    # This is test setup after schema parity; migration app settings stay fixed.
    for table in replica(0,"SELECT name FROM system.tables WHERE database='analytics' AND startsWith(engine,'Replicated') ORDER BY name"):
        replica(0,'ALTER TABLE analytics.`'+table['name']+'` MODIFY SETTING replicated_deduplication_window=0,replicated_deduplication_window_seconds=0')
    count=0
    for index,pattern in enumerate(patterns):
        # Each group gets fresh owned data, as in the existing isolated launchers.
        # Retain the baseline retention configuration and immutable native ledger.
        for table in replica(0,"SELECT name FROM system.tables WHERE database='analytics' AND startsWith(engine,'Replicated') AND name!='retention_policy' ORDER BY name"):
            replica(0,'TRUNCATE TABLE analytics.`'+table['name']+'`')
        # Hspec writes diagnostics to stderr so stdout remains the fixture RPC protocol.
        import contextlib
        with contextlib.redirect_stdout(sys.stderr):
            try:
                count+=hspec([binary('kansoku-core:test:kansoku-core-test'),'--match='+pattern],env=test_env,log=root/f'query-{index}.private',timeout=300)
            except BaseException:
                samples={}
                for table in ['events_raw','daily_event_counts','sessions']:
                    try:
                        samples[table]=[replica(i,'SELECT count() AS n FROM analytics.'+table) for i in [0,1]]
                    except Exception as observation_error:
                        samples[table]=type(observation_error).__name__
                for table in ['events_raw','events_canonical']:
                    samples[table+'-filter-account']=[replica(i,"SELECT event_id,account_id,source_service FROM analytics."+table+" WHERE startsWith(account_id,'metrics-filter-') ORDER BY event_id") for i in [0,1]]
                (root/'failed-query-observations.private').write_text(json.dumps(samples,indent=2))
                raise
    for index in [0,1]:
        replica(index,'SYSTEM SYNC DATABASE REPLICA analytics')
    for table in replica(0,"SELECT name FROM system.tables WHERE database='analytics' AND startsWith(engine,'Replicated') ORDER BY name"):
        for index in [0,1]:
            replica(index,'SYSTEM SYNC REPLICA analytics.`'+table['name']+'`')
        query='SELECT count() AS n FROM analytics.`'+table['name']+'` FINAL'
        assert replica(0,query)==replica(1,query), 'Post-query replica row counts differ'
    print(f'replicated native query/metrics: {count} examples, zero failures/pending',file=sys.stderr,flush=True)


def main():
    import signal
    def terminate(_signal, _frame):
        raise SystemExit('Owned fixture bridge terminated')
    signal.signal(signal.SIGTERM,terminate)
    Path('.dev/acceptance').mkdir(parents=True,exist_ok=True)
    case = sys.argv[1]
    fixture = json.loads(sys.stdin.readline())
    root = Path(fixture['root']) / 'kansoku'
    root.mkdir(mode=0o700)
    print(f'{case}: private evidence {root}',file=sys.stderr,flush=True)
    direct = case == 'direct'
    ids = [fixture['replicas'][0][0]['id']] if direct else [rows(r)[0]['id'] for r in fixture['replicas']]
    native = os.environ['KANSOKU_CH_MIGRATION_BINARY']
    proof = os.environ['KANSOKU_CH_MIGRATION_PROOF_BINARY']
    pg_migrate = os.environ['KANSOKU_PG_MIGRATION_BINARY']
    if direct:
        rpc('query',sql="CREATE USER app IDENTIFIED WITH plaintext_password BY 'test-password'")
        rpc('query',sql='GRANT SELECT, INSERT, CREATE DATABASE, CREATE TABLE, CREATE VIEW, ALTER TABLE, DROP TABLE, DROP VIEW, TRUNCATE, SYSTEM SYNC REPLICA, SYSTEM SYNC DATABASE REPLICA, CLUSTER, REMOTE ON *.* TO app')
    if not direct:
        import base64
        import urllib.request
        import urllib.error
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        def app_request(index,sql):
            request=urllib.request.Request(fixture['replicas'][index]['endpoint'],data=sql.encode(),headers={'Authorization':'Basic '+base64.b64encode(b'app:test-password').decode()})
            try:
                with opener.open(request,timeout=15) as response:
                    return dict(status=response.status,body=response.read(65536).decode())
            except urllib.error.HTTPError as error:
                return dict(status=error.code,body=error.read(65536).decode())
        for index in [0,1]:
            profile=rows(app_request(index,"SELECT currentUser() AS user,value FROM system.settings WHERE name='database_replicated_allow_only_replicated_engine' FORMAT JSONEachRow"))
            (root / f'profile-{index}.private').write_text(json.dumps(profile))
            assert profile==[dict(user='app',value='1')], profile
            refused=app_request(index,'SET database_replicated_allow_only_replicated_engine=0')
            assert refused['status'] != 200, 'Fixed app restriction is mutable'
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
                   KANSOKU_CH_MIGRATION_CLUSTER=fixture.get('cluster','fixture'),
                   KANSOKU_CH_MIGRATION_REPLICA_IDS=','.join(ids),
                   KANSOKU_CH_MIGRATION_LEDGER_ID=str(uuid.uuid4()),
                   KANSOKU_CLICKHOUSE_USER='app',KANSOKU_CLICKHOUSE_PASSWORD='test-password')
        if direct:
            env.pop('KANSOKU_CH_MIGRATION_CLUSTER')
            env.pop('KANSOKU_CH_MIGRATION_REPLICA_IDS')
            env.update(KANSOKU_CH_MIGRATION_SERVER_ID=ids[0],KANSOKU_CLICKHOUSE_USER='app')
        if case == 'foreign-v1':
            direct_events=json.loads(Path('.dev/acceptance/direct-control-events.private').read_text())
            initialized=json.loads(direct_events[0]['event'])
            env.update(KANSOKU_CH_MIGRATION_LEDGER_ID=direct_events[0]['ledger_id'],KANSOKU_CH_MIGRATION_TARGET=initialized['body']['target'])
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
                rpc('query',sql='CREATE TABLE kansoku_migration_ledger.events (sequence UInt64,event_id UUID,ledger_id UUID,event String) ENGINE=ReplicatedMergeTree ORDER BY sequence')
                rpc('query',sql='INSERT INTO kansoku_migration_ledger.events FORMAT JSONEachRow\n' + '\n'.join(json.dumps(row) for row in direct_events))
            if case == 'stopped':
                rpc('stop',index=1)
            success = case in ('tiny','direct','full','fresh','hyphen')
            def replica(index, sql):
                return rpc('query',sql=sql) if direct else rows(rpc('replica',index=index,sql=sql))
            if case in ('direct','full','nonquorum'):
                from diagnostic_session_upgrade import seed, observation, expected, insert_after, repair_args
                entry(['--proof-historical-prefix','up','--initialize-ledger',env['KANSOKU_CH_MIGRATION_LEDGER_ID']],executable=proof)
                def query(sql):return replica(0,sql)
                def sync():
                    if not direct:
                        for i in [0,1]:
                            replica(i,'SYSTEM SYNC DATABASE REPLICA analytics')
                            for table in ['events_raw','retention_policy','sessions']:
                                replica(i,'SYSTEM SYNC REPLICA analytics.'+table+' STRICT')
                sync()
                seed(query)
                sync()
                for i in ([0] if direct else [0,1]):
                    assert observation(lambda sql:replica(i,sql))==expected(1)
                if case=='nonquorum':
                    # Deliberately violate the supported historical writer contract.
                    # Native quorum-prefix reads must not silently authorize release.
                    replica(0,"INSERT INTO analytics.retention_policy(singleton,revision,cutoff) SETTINGS insert_quorum=0 VALUES (1,100,toDateTime64('2026-07-02',3,'UTC'))")
                    sync()
                    refused=entry(['up'],False)
                    primary=refused['error']['primary']
                    assert primary['code']=='callback-failed' and primary['callback']['phase']=='BeforeMigrationComplete', primary
                    assert pg('SELECT count(*) FROM kansoku.maintenance_fence WHERE active_migration_session IS NOT NULL')=='1'
                    entry(['maintenance','finish'],False)
                    assert pg('SELECT count(*) FROM kansoku.maintenance_fence WHERE active_migration_session IS NOT NULL')=='1'
                    (root/'nonquorum-guard.private.json').write_text(json.dumps(dict(full_history_verification_refused=True,fence_retained=True)))
                    print('nonquorum: complete-history comparison refused partial reconstruction; fence retained',file=sys.stderr,flush=True)
                    return
                if case=='full':
                    proxy.match=b'TRUNCATE TABLE analytics.sessions'
                    entry(['up'],False)
                    assert proxy.triggered.is_set()
                    sync()
                    for i in [0,1]:
                        assert replica(i,'SELECT count() AS n FROM analytics.sessions')==[dict(n=0)]
                    assert pg('SELECT count(*) FROM kansoku.maintenance_fence WHERE active_migration_session IS NOT NULL')=='1'
                    entry(['up'],False)
                    entry(['maintenance','finish'],False)
                    entry(['maintenance','reconcile'],False)
                    state=invoke(['status','--guarded','--json'])
                    entry(repair_args(state,'accept-step',True))
                    state=invoke(['status','--guarded','--json'])
                    entry(repair_args(state,'resume'))
                else:
                    entry(['up'])
                sync()
                for i in ([0] if direct else [0,1]):
                    assert observation(lambda sql:replica(i,sql))==expected(0)
                insert_after(query)
                sync()
                for i in ([0] if direct else [0,1]):
                    assert observation(lambda sql:replica(i,sql))==expected(0)
                replay=Path('kansoku-server/migrations/'+('clickhouse' if direct else 'clickhouse-replicated')+'/steps/0026_diagnostic_session_engagement/rebuild-sessions.sql').read_text()
                for _ in range(2):
                    replica(0,'TRUNCATE TABLE analytics.sessions')
                    sync()
                    replica(0,replay)
                    sync()
                    for i in ([0] if direct else [0,1]):
                        assert observation(lambda sql:replica(i,sql))==expected(0)
                # Adjacent query families own their own seeds and original cutoff.
                replica(0,'TRUNCATE TABLE analytics.events_raw')
                replica(0,'TRUNCATE TABLE analytics.sessions')
                replica(0,"INSERT INTO analytics.retention_policy(singleton,revision,cutoff) VALUES (1,100,toDateTime64('1970-01-01',3,'UTC'))")
                sync()
            else:
                entry(['up','--initialize-ledger',env['KANSOKU_CH_MIGRATION_LEDGER_ID']],success)
            assert pg('SELECT count(*) FROM kansoku.maintenance_fence WHERE active_migration_session IS NOT NULL') == '1'
            if not success:
                assert proxy.application_count() == 0
                print(f'{case}: refused; fence retained; zero application requests',file=sys.stderr,flush=True)
                return
            invoke(['verify','--require-current','--guarded','--json'])
            status = invoke(['status','--json'])
            (root / 'status.json').write_text(json.dumps(status,indent=2))
            selected=status['selectedTarget']
            assert selected==({'topology':'direct','serverId':ids[0]} if direct else {'topology':'replicated','cluster':fixture.get('cluster','fixture'),'replicaIds':sorted(ids)})
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
            entry(['maintenance','finish'])
            before = proxy.application_count()
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
                def parity_query(sql, input=None):
                    values=rpc('query',sql=sql + ('\n'+input if input else ''))
                    return '\n'.join('\t'.join(str(row[k]) for k in sorted(row)) for row in values)
                data=parity_observation(parity_query)
                data_file=parity_file.with_suffix('.data.private')
                if direct:
                    parity_file.write_text(json.dumps(snapshot))
                    data_file.write_text(json.dumps(data))
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
                    actual,expected=normalized(snapshot),normalized(json.loads(parity_file.read_text()))
                    (root/'schema-comparison.private').write_text(json.dumps(dict(actual=actual,expected=expected),indent=2))
                    assert actual==expected, f'Direct/replicated schema differs; evidence {root}'
                    assert normalized(snapshot)==normalized(replica(1,schema_sql)), 'Replica schemas differ'
                    assert data==json.loads(data_file.read_text()), 'Direct/replicated seeded raw, rollup or reader results differ'
                    def second(sql,input=None):
                        if input is not None: return ''
                        values=replica(1,sql)
                        return '\n'.join('\t'.join(str(row[k]) for k in sorted(row)) for row in values)
                    import time
                    deadline=time.monotonic()+15
                    while True:
                        try:
                            assert parity_observation(second)==data
                            break
                        except AssertionError:
                            if time.monotonic()>=deadline: raise
                            time.sleep(.1)
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
                        for index in [0,1]:
                            replica(index,'SYSTEM SYNC REPLICA analytics.`'+item['name']+'`')
                        counts=[replica(index,'SELECT count() AS n FROM analytics.`'+item['name']+'` FINAL') for index in [0,1]]
                        assert counts[0]==counts[1], (item['name'],counts)
                native_examples(env, fixture, root, replica)
                begin()
                entry(['up'],executable=proof)
                upgraded_events=events()
                assert upgraded_events[0]==upgraded_events[1]
                assert upgraded_events[0][:len(before_events[0])]==before_events[0], 'Upgrade rewrote baseline history'
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
