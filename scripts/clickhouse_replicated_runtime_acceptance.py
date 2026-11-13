#!/usr/bin/env python3
"""Required, owned native runtime proof. Missing prerequisites fail visibly."""
import argparse
import atexit
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import uuid

from isolated_postgres import isolated_postgres
from replicated_clickhouse import NativeProxy, native_ports, configure_owned_capacity
from test_support import binary, execute


def rpc(op, *, allow_error=False, **values):
    print(json.dumps(dict(op=op, **values)), file=sys.__stdout__, flush=True)
    line = sys.stdin.readline()
    if not line:
        raise RuntimeError('Owned fixture exited')
    result=json.loads(line)
    if isinstance(result,dict) and 'fixtureError' in result and not allow_error:
        raise RuntimeError('Owned fixture operation failed: '+op)
    return result


def rows(response):
    assert response['status'] == 200, response['body']
    return [json.loads(line) for line in response['body'].splitlines() if line.strip()]


def main():
    def terminate(_signal,_frame):
        raise SystemExit('Owned runtime fixture terminated')
    signal.signal(signal.SIGTERM,terminate)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', choices=['topology', 'maintenance', 'rebuild', 'writer', 'readback'])
    parser.add_argument('--packaged', action='store_true')
    parser.add_argument('--owned-bridge', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    driver = os.environ.get('KANSOKU_REPLICATED_RUNTIME_BINARY') or subprocess.check_output(['cabal','list-bin','kansoku-server:test:clickhouse-replicated-runtime','-fnative-migration-tests'],text=True).strip()
    if not args.owned_bridge:
        if args.packaged:
            packages=json.loads(subprocess.check_output(['nix','build','.#kansoku-server','--no-link','--no-write-lock-file','--json'],text=True))
            output=packages[0]['outputs']['out']+'/bin/'
            os.environ.update(KANSOKU_SERVER_BINARY=output+'kansoku-server',KANSOKU_ADMIN_BINARY=output+'kansoku-admin',KANSOKU_CH_MIGRATION_BINARY=output+'kansoku-ch-migrate',KANSOKU_PG_MIGRATION_BINARY=output+'kansoku-migrate')
        cases=[args.case] if args.case else ['topology','maintenance','rebuild','writer','readback']
        for case in cases:
            command=[driver,'--case',case]+(['--packaged'] if args.packaged else [])
            if sys.platform == 'darwin':
                from native_clickhouse_fixture import fixture, run_bridge
                with fixture() as (data, query, request, lifecycle):
                    for db in ['analytics', 'kansoku_migration_ledger']:
                        query(0, "CREATE DATABASE " + db + " ON CLUSTER fixture ENGINE=Replicated('/clickhouse/databases/{uuid}', '{shard}', '{replica}')")
                    run_bridge([sys.executable, __file__, '--owned-bridge', '--case', case] + (['--packaged'] if args.packaged else []), data, query, request, lifecycle, timeout=1800)
            else:
                subprocess.run(command,check=True)
        print('Replicated runtime acceptance passed: '+', '.join(cases)+'; 2 replicas verified.')
        return
    fixture = json.loads(sys.stdin.readline())
    root = Path('.dev/acceptance') / ('runtime-' + uuid.uuid4().hex)
    root.mkdir(mode=0o700, parents=True)
    print(f'Runtime private evidence: {root}', file=sys.stderr, flush=True)
    ids = [rows(r)[0]['id'] for r in fixture['replicas']]
    ports = native_ports(fixture, root)
    report = dict(replicas=ids, executables='nix' if args.packaged else 'cabal', nativeDriver='cabal', packaged=args.packaged, status='failed', outcomes={}, containers=json.loads((root/'containers.private.json').read_text()))
    atexit.register(lambda: (root/'report.private.json').write_text(json.dumps(report,indent=2)))
    (root/'fixture.private.json').write_text(json.dumps(fixture,indent=2))
    report['serverCapacity']=configure_owned_capacity(root)
    if fixture.get('engine') not in ('apple', 'nix'):
        for index in [0,1]:
            rpc('start',index=index)
    def replica(i, sql):
        return rows(rpc('replica', index=i, sql=sql))
    selected_binaries={key:value for key,value in os.environ.items() if key in ['KANSOKU_SERVER_BINARY','KANSOKU_ADMIN_BINARY','KANSOKU_CH_MIGRATION_BINARY','KANSOKU_PG_MIGRATION_BINARY']}
    with isolated_postgres(root / 'postgres') as env, NativeProxy(ports) as proxy:
        migrate = os.environ.get('KANSOKU_CH_MIGRATION_BINARY') or binary('kansoku-server:exe:kansoku-ch-migrate')
        pg_migrate = os.environ.get('KANSOKU_PG_MIGRATION_BINARY') or binary('kansoku-server:exe:kansoku-migrate')
        env.update(selected_binaries)
        env.update(KANSOKU_CH_MIGRATION_TARGET='kansoku/runtime-' + uuid.uuid4().hex,
                   KANSOKU_CH_MIGRATION_ENDPOINT=fixture['endpoint'],
                   KANSOKU_CH_MIGRATION_CLUSTER='fixture',
                   KANSOKU_CH_MIGRATION_REPLICA_IDS=','.join(ids),
                   KANSOKU_CH_MIGRATION_LEDGER_ID=str(uuid.uuid4()),
                   KANSOKU_CLICKHOUSE_HOST='127.0.0.1',CLICKHOUSE_TCP_PORT=str(proxy.port),
                   KANSOKU_CLICKHOUSE_USER='app',KANSOKU_CLICKHOUSE_PASSWORD='test-password')
        sequence = 0
        def run(command, *, success=True, selected=None, input=None, timeout=180):
            nonlocal sequence
            sequence += 1
            result = execute(command,env=selected or env,input=input,timeout=timeout)
            (root/f'command-{sequence}.private').write_text(result.stdout+result.stderr)
            assert (result.returncode == 0) == success, f'command {sequence}: {result.stderr}; evidence {root}'
            return result.stdout
        report['serverVersions']=[replica(i,'SELECT version() AS version')[0]['version'] for i in [0,1]]
        assert report['serverVersions']==[fixture.get('version', '26.3.60.10002.altinitystable')]*2
        run([pg_migrate,'up'])
        def invoke(command):
            return json.loads(run([migrate,*command,'--json']))
        begun=invoke(['maintenance','begin','--expect-target',env['KANSOKU_CH_MIGRATION_TARGET'],'--actor','owned runtime proof','--reason','Plan 63 native runtime'])
        env['KANSOKU_CH_MIGRATION_SESSION']=begun['result']['id']
        evidence=['--expect-target',env['KANSOKU_CH_MIGRATION_TARGET'],'--actor','owned runtime proof','--reason','owned synchronous clients completed','--quiescent','--evidence',str(root)]
        invoke(['--predecessor','0','up','--initialize-ledger',env['KANSOKU_CH_MIGRATION_LEDGER_ID'],*evidence])
        # The CLI binds each drain attestation to the previous entry counter.
        status=invoke(['maintenance','status'])
        entry=status['result']['entry']
        invoke(['--predecessor',str(entry),'maintenance','finish',*evidence])
        env.pop('KANSOKU_CH_MIGRATION_SESSION')
        for i in [0,1]:
            replica(i,"CREATE USER runtime IDENTIFIED WITH plaintext_password BY 'test-password' SETTINGS async_insert=0,max_result_rows=0,max_result_bytes=0,result_overflow_mode='throw',read_overflow_mode='throw'")
            replica(i,'GRANT SELECT, INSERT, ALTER TABLE, TRUNCATE, SYSTEM SYNC REPLICA, SYSTEM SYNC DATABASE REPLICA ON *.* TO runtime')
            replica(i,'GRANT READ ON REMOTE TO runtime')
        env['KANSOKU_CLICKHOUSE_USER']='runtime'
        def native(operation, **kwargs):
            return run([driver,'--native',operation],**kwargs)
        report['settings']={role:[json.loads(run([driver,'--native','settings',role],selected=dict(env,CLICKHOUSE_TCP_PORT=str(p)))) for p in ports] for role in ['writer','maintenance','readback']}
        observed=json.loads(native('topology'))
        assert sorted(observed)==sorted(ids),observed
        if args.case in (None,'topology'):
            with NativeProxy([ports[0]]) as pinned_proxy:
                pinned=dict(env,CLICKHOUSE_TCP_PORT=str(pinned_proxy.port))
                native('topology',selected=pinned,success=False,timeout=45)
                assert pinned_proxy.idle.wait(3),'failed acquisition leaked retained or duplicate handles'
            changed=dict(env,KANSOKU_CH_MIGRATION_REPLICA_IDS=ids[0]+',00000000-0000-0000-0000-000000000000')
            native('topology',selected=changed,success=False,timeout=45)
            assert proxy.idle.wait(3),'unexpected UUID leaked acquired handles'
            direct={k:v for k,v in env.items() if k not in ('KANSOKU_CH_MIGRATION_CLUSTER','KANSOKU_CH_MIGRATION_REPLICA_IDS')}
            native('topology',selected=direct,success=False)
            report['outcomes']['topology']='passed'
        # A real native insert on A followed by production same-connection
        # synchronization and canonical/public read on B is the integration gate.
        event=dict(eventId='runtime-roundtrip',eventName='page_view',source='web',sourceService='runtime-proof',
                   occurredAt='2026-11-07T12:00:00Z',receivedAt='2026-11-07T12:00:01Z',accountId='runtime-account',
                   userId='runtime-user',context={},schemaVersion=1,properties={'url':'https://example.test/route'})
        payload=json.dumps([event])
        native('write',input=payload)
        actual=json.loads(native('readback',selected=dict(env,CLICKHOUSE_TCP_PORT=str(ports[1]))))
        assert 'runtime-roundtrip' in actual,actual
        pooled=json.loads(native('pooled-readback',selected=dict(env,CLICKHOUSE_TCP_PORT=str(ports[1]))))
        assert pooled==actual,'fresh pooled read-back differs'
        report['outcomes']['readback']='passed'
        rich=[dict(event,eventId='seed-identify',eventName='identify',schemaVersion=2,anonymousId='runtime-cookie',sessionId='runtime-session',identifiers={'cookie':'runtime-cookie','device':'runtime-device','fingerprint':'runtime-fingerprint'},properties={'plan':'pro'}),
              dict(event,eventId='seed-once',eventName='identify_once',properties={'country':'US'}),
              dict(event,eventId='seed-group',eventName='group',schemaVersion=2,organizationId='runtime-org',properties={'plan':'enterprise','seats':10}),
              dict(event,eventId='seed-member',organizationId='runtime-org',sessionId='runtime-session',anonymousId='runtime-cookie'),
              dict(event,eventId='seed-experiment',eventName='experiment_viewed',properties={'experiment':'runtime_exp','variant':'a'})]
        prepared=native('prepare',input=json.dumps(rich))
        native('write',input=prepared)
        native('topology')
        # Explicitly owned fault cases. All process handles and logs belong to
        # this fixture, and independent observations always name each replica.
        import contextlib
        import time
        from isolated_clickhouse import free_port
        admin = os.environ.get('KANSOKU_ADMIN_BINARY') or binary('kansoku-server:exe:kansoku-admin')
        server = os.environ.get('KANSOKU_SERVER_BINARY') or binary('kansoku-server:exe:kansoku-server')
        env.update(KANSOKU_QUEUE_NAME='runtime_events',KANSOKU_SERVER_PORT=str(free_port()),
                   KANSOKU_WRITER_MAX_BATCH='1',KANSOKU_WRITER_MAX_LATENCY_MS='50',
                   KANSOKU_QUEUE_POLL_INTERVAL_SEC='1',OTEL_TRACES_EXPORTER='none')
        def pg(sql):
            return run(['psql','-XAt','-v','ON_ERROR_STOP=1','-c',sql]).strip()
        pg("SELECT pgmq.create('runtime_events')")
        def eventually(check,label,seconds=60):
            deadline=time.monotonic()+seconds
            while time.monotonic()<deadline:
                if check():
                    return
                time.sleep(.1)
            raise AssertionError('deadline: '+label)
        def restore_replica(index):
            result=rpc('start',index=index,allow_error=True)
            if isinstance(result,dict) and 'fixtureError' in result:
                report.setdefault('fixtureInitialReadinessRefusals',[]).append(index)
            # Start exactly once. Independently prove that this same owned UUID
            # has completed recovery before resuming any fenced job.
            def writable():
                try:
                    state=replica(index,"SELECT toString(serverUUID()) AS id,(SELECT count() FROM system.database_replicas WHERE is_readonly) AS databases_readonly,(SELECT count() FROM system.replicas WHERE database='analytics' AND is_readonly) AS tables_readonly,(SELECT count() FROM system.replicas WHERE database='analytics') AS table_count")[0]
                    assert state['id']==ids[index],'restored replica identity changed'
                    report.setdefault('restoredReplicaObservations',[]).append(dict(replica=index,state=state))
                    return state['databases_readonly']==0 and state['tables_readonly']==0 and state['table_count']>=18
                except RuntimeError:
                    return False
            eventually(writable,'restored owned replica writable',60)
        @contextlib.contextmanager
        def child(command,selected=None,input=None):
            nonlocal sequence
            sequence+=1
            path=root/f'process-{sequence}.private'
            with path.open('w') as log:
                process=subprocess.Popen(command,env=selected or env,stdin=subprocess.PIPE if input else subprocess.DEVNULL,stdout=log,stderr=log,text=True)
                with (root/'processes.private.jsonl').open('a') as inventory:
                    inventory.write(json.dumps(dict(pid=process.pid,command=command))+'\n')
                if input:
                    process.stdin.write(input)
                    process.stdin.close()
                try:
                    yield process,path
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
        def wait_child(process,path,success=True):
            result=process.wait(timeout=150)
            if (result==0)!=success:
                identifier=fence()
                if identifier and success:
                    diagnostic=execute([driver,'--native','resume-trace',identifier],env=env,timeout=180)
                    (root/'failed-resume-trace.private').write_text(diagnostic.stdout+diagnostic.stderr)
                raise AssertionError(str(path))
            return path.read_text()
        def fence():
            identifier=pg('SELECT active_job::text FROM kansoku.maintenance_fence WHERE singleton')
            report.setdefault('fenceObservations',[]).append(dict(job=identifier,at=time.time()))
            return identifier
        def stage():
            value=pg('SELECT j.stage FROM kansoku.maintenance_jobs j JOIN kansoku.maintenance_fence f ON j.id=f.active_job')
            report.setdefault('stageObservations',[]).append(dict(stage=value,at=time.time()))
            return value
        def erase(user='runtime-user'):
            return [admin,'erase-user','--account','runtime-account','--user',user,'--confirm']
        def resume(identifier,selected=None,success=True):
            return run([admin,'resume-job','--id',identifier,'--confirm'],selected=selected,success=success)
        def job_complete(identifier):
            assert fence()=='', 'successful job retained fence'
            assert pg("SELECT stage FROM kansoku.maintenance_jobs WHERE id='"+identifier+"'")=='complete'
        def sync():
            # Writer assertions deliberately stop raw merges. STRICT would also
            # wait for those paused merge tasks; acknowledged quorum writes
            # already establish part delivery. Revalidate UUID coverage here,
            # then independently inspect both endpoints without merging raw.
            native('inventory' if args.case=='writer' else 'topology')
        def physical(key):
            return [int(replica(i,"SELECT count() AS n FROM analytics.events_raw WHERE event_id='"+key+"'")[0]['n']) for i in [0,1]]
        def snapshots():
            # Finalize every state column using the installed target schema.
            # GROUP BY ALL combines states before comparison; physical part
            # merging is deliberately unnecessary for these assertions.
            targets=['identity_signals','identity_signal_users','identity_session_users','identity_context_signals','daily_event_counts','page_views_by_route','dau','wau','experiment_exposures','sessions','user_properties','user_properties_once','organization_properties','user_organizations']
            result={}
            for table in targets:
                columns=replica(0,"SELECT name,type FROM system.columns WHERE database='analytics' AND table='"+table+"' ORDER BY position")
                expressions=[]
                for column in columns:
                    name='`'+column['name']+'`'
                    typ=column['type']
                    if typ.startswith('AggregateFunction('):
                        aggregate=typ[len('AggregateFunction('):].split(',')[0]
                        expressions.append(aggregate+'Merge('+name+') AS '+name)
                    else:
                        expressions.append(name)
                sql='SELECT '+','.join(expressions)+' FROM analytics.`'+table+'` FINAL GROUP BY ALL ORDER BY ALL'
                observed=[replica(i,sql) for i in [0,1]]
                assert observed[0]==observed[1], 'aggregate replica mismatch: '+table
                source=replica(0,"SELECT as_select FROM system.tables WHERE database='analytics' AND name='mv_"+table+"'")[0]['as_select'].replace('analytics.events_raw','analytics.events_canonical')
                expected=replica(0,'SELECT '+','.join(expressions)+' FROM ('+source+') GROUP BY ALL ORDER BY ALL')
                assert observed[0]==expected,'finalized target differs from canonical source: '+table
                result[table]=observed[0]
            return result
        if args.case=='maintenance':
            held=dict(event,eventId='held-before-discovery')
            with NativeProxy([ports[0]]) as held_proxy, NativeProxy([ports[1],ports[0]]) as maintenance_proxy:
                held_proxy.client_marker=b'held-before-discovery'
                held_proxy.client_hold.set()
                writer_env=dict(env,CLICKHOUSE_TCP_PORT=str(held_proxy.port))
                with child([driver,'--native','write'],writer_env,json.dumps([held])) as (writer,writer_log):
                    assert held_proxy.client_seen.wait(15),'native writer never reached row transmission'
                    assert replica(0,"SELECT count() AS n FROM system.processes WHERE query_kind='Insert' AND position(query,'events_raw')>0")[0]['n']>0
                    with child(erase(),dict(env,CLICKHOUSE_TCP_PORT=str(maintenance_proxy.port))) as (job,job_log):
                        eventually(lambda:bool(fence()),'persist held-insert job')
                        identifier=fence()
                        time.sleep(1)
                        assert job.poll() is None and stage()=='created','discovery advanced before all-replica drain'
                        held_proxy.client_hold.clear()
                        wait_child(writer,writer_log)
                        wait_child(job,job_log)
                        job_complete(identifier)
            # Missing A fails before discovery and leaves its retained identity.
            rpc('stop',index=0)
            run(erase('absent-user'),success=False,timeout=90)
            identifier=fence()
            assert identifier and stage()=='created'
            wrong=dict(env,KANSOKU_CH_MIGRATION_CLUSTER='changed',CLICKHOUSE_TCP_PORT='1')
            resume(identifier,wrong,False)
            assert stage()=='created'
            restore_replica(0)
            resume(identifier)
            job_complete(identifier)
            # A paused mutation cannot produce a successful completion receipt.
            replica(0,'SYSTEM STOP MERGES analytics.events_raw')
            with child(erase('runtime-user')) as (job,job_log):
                eventually(lambda:bool(fence()),'persist paused-mutation job')
                identifier=fence()
                eventually(lambda:bool(replica(0,"SELECT mutation_id FROM system.mutations WHERE database='analytics' AND table='events_raw' AND NOT is_done")),'register mutation')
                assert job.poll() is None and fence()==identifier
                job.terminate()
                job.wait(timeout=10)
            replica(0,'SYSTEM START MERGES analytics.events_raw')
            resume(identifier)
            job_complete(identifier)
            # Explicit observation permission denial must retain the fence.
            for i in [0,1]:
                replica(i,'REVOKE SELECT ON system.processes FROM runtime')
            run(erase('permission-case'),success=False)
            identifier=fence()
            assert identifier and stage()=='created'
            for i in [0,1]:
                replica(i,'GRANT SELECT ON system.processes TO runtime')
            resume(identifier)
            job_complete(identifier)
            # Retention must retain the same fence through a missing replica,
            # then scrub old fingerprints and rebuild after deliberate resume.
            old=dict(event,eventId='retention-old',occurredAt='2026-01-01T12:00:00Z',receivedAt='2026-01-01T12:00:01Z',identifiers={'fingerprint':'expired-fingerprint'})
            native('write',input=json.dumps([old]))
            retained=dict(env,KANSOKU_EVENTS_RETENTION_DAYS='365')
            rpc('stop',index=0)
            run([admin,'apply-retention','--confirm'],selected=retained,success=False,timeout=90)
            identifier=fence()
            assert identifier and stage()=='created'
            restore_replica(0)
            resume(identifier,retained)
            job_complete(identifier)
            for i in [0,1]:
                remaining=replica(i,"SELECT count() AS n FROM analytics.events_raw WHERE event_id='retention-old' AND JSONHas(identifiers,'fingerprint')")[0]['n']
                assert remaining==0,'retained expired fingerprint survived'
            run([admin,'apply-retention','--confirm'],selected=dict(env,KANSOKU_EVENTS_RETENTION_DAYS='1'))
            assert physical('retention-old')==[0,0]
            report['jobs']=json.loads(pg("SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'stage',stage,'identity',target_identity)),'[]'::jsonb) FROM kansoku.maintenance_jobs"))
            report['outcomes']['maintenance']='passed'
        if args.case=='rebuild':
            before=snapshots()
            # Pause a statement only after the real server has committed it,
            # then terminate before the PostgreSQL rebuilt checkpoint.
            for point in ['TRUNCATE TABLE analytics.identity_signals','INSERT INTO analytics.identity_signals']:
                with NativeProxy([ports[1],ports[0]]) as job_proxy:
                    job_proxy.reply_marker=point.encode()
                    with child(erase('no-such-user'),dict(env,CLICKHOUSE_TCP_PORT=str(job_proxy.port))) as (job,job_log):
                        eventually(lambda:bool(fence()),'persist interrupted rebuild')
                        identifier=fence()
                        assert job_proxy.seen.wait(60),'rebuild boundary reply not held'
                        def reached():
                            observed=[replica(i,'SELECT count() AS n FROM analytics.identity_signals')[0]['n'] for i in [0,1]]
                            active=[replica(i,"SELECT count() AS n FROM system.processes WHERE startsWith(query,'"+point+"')")[0]['n'] for i in [0,1]]
                            expected=all(n==0 for n in observed) if point.startswith('TRUNCATE') else all(n>0 for n in observed)
                            return expected and active==[0,0]
                        eventually(reached,'commit rebuild boundary',60)
                        job.terminate()
                        job.wait(timeout=10)
                        job_proxy.drop.set()
                        assert fence()==identifier and stage()!='complete'
                resume(identifier)
                job_complete(identifier)
                sync()
                assert snapshots()==before,'interrupted rebuild changed finalized targets'
            # Pause the real PostgreSQL checkpoint at the rebuilt and verified
            # boundaries, then stop a replica before the next completion check.
            for checkpoint in ['rebuilt','verified']:
                pg("CREATE OR REPLACE FUNCTION kansoku.runtime_checkpoint_pause() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(5); RETURN NEW; END $$; CREATE TRIGGER runtime_checkpoint_pause BEFORE UPDATE ON kansoku.maintenance_jobs FOR EACH ROW WHEN (NEW.stage='"+checkpoint+"') EXECUTE FUNCTION kansoku.runtime_checkpoint_pause()")
                with child(erase('final-check-user')) as (job,job_log):
                    eventually(lambda:bool(fence()),'persist final-verification job')
                    identifier=fence()
                    eventually(lambda:pg("SELECT count(*) FROM pg_stat_activity WHERE wait_event='PgSleep' AND query LIKE 'UPDATE kansoku.maintenance_jobs%' ")!='0','pause real stage checkpoint')
                    rpc('stop',index=0)
                    wait_child(job,job_log,False)
                    assert fence()==identifier and stage()==checkpoint
                pg('DROP TRIGGER runtime_checkpoint_pause ON kansoku.maintenance_jobs; DROP FUNCTION kansoku.runtime_checkpoint_pause()')
                resume(identifier,success=False)
                assert fence()==identifier and stage()==checkpoint,'saved verification released a missing replica'
                restore_replica(0)
                resume(identifier)
                job_complete(identifier)
                sync()
                assert snapshots()==before
            report['outcomes']['rebuild']='passed'
        if args.case=='writer':
            for i in [0,1]:
                replica(i,'SYSTEM STOP MERGES analytics.events_raw')
            def send(row):
                value=json.dumps(row).replace("'","''")
                pg("SELECT pgmq.send('runtime_events','"+value+"'::jsonb)")
            def empty():
                return pg('SELECT count(*) FROM pgmq.q_runtime_events')=='0'
            with child([server]) as (application,application_log):
                warm=dict(event,eventId='writer-warm')
                send(warm)
                eventually(empty,'warm real writer')
                # Pin recovered traffic to A first; full quorum still requires B.
                rpc('stop',index=1)
                stopped=dict(event,eventId='writer-stopped')
                send(stopped)
                time.sleep(3)
                assert not empty(),'queue acknowledged while a replica was stopped'
                restore_replica(1)
                for i in [0,1]:
                    replica(i,'SYSTEM STOP MERGES analytics.events_raw')
                eventually(empty,'recover stopped-replica write',90)
                sync()
                assert physical('writer-stopped')==[1,1]
                before=snapshots()
                # Unique row bytes arm the proxy after handshake, settings and
                # INSERT sample negotiation. Observe server commit independently.
                keeper_path=replica(0,"SELECT zookeeper_path FROM system.replicas WHERE database='analytics' AND table='events_raw'")[0]['zookeeper_path']+'/blocks'
                def block_nodes():
                    quoted=keeper_path.replace("'","''")
                    return {row['name'] for row in replica(0,"SELECT name FROM system.zookeeper WHERE path='"+quoted+"'")}
                before_lost_nodes=block_nodes()
                lost=dict(event,eventId='writer-lost-ack')
                proxy.reply_marker=b'writer-lost-ack'
                proxy.trace_marker=b'writer-lost-ack'
                send(lost)
                assert proxy.seen.wait(20),'INSERT completion was never held'
                eventually(lambda:physical('writer-lost-ack')==[1,1],'commit before losing acknowledgement')
                assert not empty(),'queue acknowledged a withheld success reply'
                eventually(lambda:all(replica(i,"SELECT count() AS n FROM system.processes WHERE query_kind='Insert' AND position(query,'events_raw')>0")[0]['n']==0 for i in [0,1]),'finish all dependent writes before lost acknowledgement')
                lost_nodes=block_nodes()-before_lost_nodes
                assert lost_nodes,'lost-ack block identity was not observed in Keeper'
                report['lostAckDeduplicationIds']=sorted(lost_nodes)
                committed=snapshots()
                first_port=proxy.held_port
                retry_port=next(port for port in ports if port!=first_port)
                with proxy.lock:
                    proxy.forced_port=retry_port
                proxy.drop.set()
                assert proxy.dropped.wait(5),'held native reply connection was not closed'
                eventually(empty,'actual writer recovery retry',90)
                assert len(proxy.trace_ports)>=2 and proxy.trace_ports[:2]==[first_port,retry_port],'lost-ack retry did not traverse the other replica'
                report['lostAckReplicaRoute']=[ids[ports.index(port)] for port in proxy.trace_ports[:2]]
                with proxy.lock:
                    proxy.forced_port=None
                sync()
                assert physical('writer-lost-ack')==[1,1],'identical retry duplicated physical raw rows'
                assert snapshots()==committed,'identical retry changed finalized target values'
                report['physicalLostAck']=physical('writer-lost-ack')
                # Fail one materialized-view target after the source can commit.
                replica(0,"ALTER TABLE analytics.daily_event_counts ADD CONSTRAINT runtime_failure CHECK event_name!='runtime_mv_failure'")
                for i in [0,1]:
                    replica(i,'SYSTEM SYNC DATABASE REPLICA analytics')
                failed=dict(event,eventId='writer-view-failure',eventName='runtime_mv_failure')
                send(failed)
                eventually(lambda:physical('writer-view-failure')==[1,1],'source commit despite failed materialized view')
                assert not empty(),'failed materialized view acknowledged the queue'
                replica(0,'ALTER TABLE analytics.daily_event_counts DROP CONSTRAINT runtime_failure')
                for i in [0,1]:
                    replica(i,'SYSTEM SYNC DATABASE REPLICA analytics')
                eventually(empty,'recover partial materialized-view delivery',90)
                sync()
                snapshots()
            # Redelivery after restart changes batching. Logical facts and all
            # finalized targets remain correct independently of physical copies.
            regroup=[dict(event,eventId='regroup-'+str(n)) for n in range(4)]
            native('write',input=json.dumps(regroup))
            with child([server],dict(env,KANSOKU_WRITER_MAX_BATCH='2')) as (application,application_log):
                for row in regroup:
                    send(row)
                eventually(empty,'regrouped restart redelivery')
                sync()
                snapshots()
            # Two partitions force multiple server blocks from the native batch.
            blocks=[dict(event,eventId='block-'+str(n),occurredAt=stamp,receivedAt=stamp) for n,stamp in enumerate(['2026-10-01T12:00:00Z','2026-11-07T12:00:00Z'])]
            native('write',input=json.dumps(blocks))
            native('write',input=json.dumps(blocks))
            sync()
            report['multipleBlockPhysical']={row['eventId']:physical(row['eventId']) for row in blocks}
            for row in blocks:
                assert all(replica(i,"SELECT count() AS n FROM analytics.events_canonical WHERE event_id='"+row['eventId']+"'")[0]['n']==1 for i in [0,1]),'multiple-block logical replay duplicated an event'
            snapshots()
            # Shrink only the owned fixture windows and evict old block IDs.
            tables=replica(0,"SELECT name FROM system.tables WHERE database='analytics' AND startsWith(engine,'Replicated') ORDER BY name")
            for table in tables:
                replica(0,'ALTER TABLE analytics.`'+table['name']+'` MODIFY SETTING replicated_deduplication_window=1,replicated_deduplication_window_seconds=1')
            for n in range(3):
                native('write',input=json.dumps([dict(event,eventId='evict-'+str(n))]))
            eventually(lambda:not (lost_nodes & block_nodes()),'observe expired deduplication identities',60)
            report['lostAckDeduplicationIdsExpired']=True
            native('write',input=json.dumps([lost]))
            sync()
            report['expiredWindowPhysical']=physical('writer-lost-ack')
            assert all(n>=2 for n in report['expiredWindowPhysical']),'fixture did not expire old deduplication identity'
            report['aggregates']=snapshots()
            report['outcomes']['writer']='passed'
        if args.case=='readback':
            # Hold a required source's replication queue after an owned no-quorum
            # fixture write. The read-back must wait for the explicit barrier.
            replica(1,'SYSTEM STOP FETCHES analytics.retention_policy')
            replica(0,"INSERT INTO analytics.retention_policy VALUES (1,1000,'1970-01-01 00:00:00')")
            with child([driver,'--native','readback'],dict(env,CLICKHOUSE_TCP_PORT=str(ports[1]))) as (reader,reader_log):
                eventually(lambda:replica(1,"SELECT count() AS n FROM system.processes WHERE startsWith(query,'SYSTEM SYNC REPLICA analytics.`retention_policy` STRICT')")[0]['n']>0,'read-back blocked on required source barrier')
                assert reader.poll() is None,'read-back returned while a required source was behind'
                replica(1,'SYSTEM START FETCHES analytics.retention_policy')
                wait_child(reader,reader_log)
            report['outcomes']['readback']='passed'
        if args.case=='topology':
            identifier=pg("WITH created AS (INSERT INTO kansoku.maintenance_jobs(kind,scope) VALUES('erase-user','{}') RETURNING id) UPDATE kansoku.maintenance_fence SET active_job=(SELECT id FROM created) WHERE singleton RETURNING active_job::text")
            # psql emits a command status for UPDATE RETURNING; take the UUID.
            identifier=identifier.splitlines()[0]
            rejected=execute([admin,'resume-job','--id',identifier,'--confirm'],env=dict(env,CLICKHOUSE_TCP_PORT='1'),timeout=10)
            assert rejected.returncode!=0 and 'mismatch' in rejected.stderr,'historical direct job was adopted or native work was attempted'
            assert fence()==identifier and stage()=='created'
            report['historicalDirectRefusal']=True
        report['aggregates']=snapshots()
        report['mutations']=[replica(i,"SELECT table,mutation_id,is_done,(latest_fail_reason!='') AS failed FROM system.mutations WHERE database='analytics' ORDER BY table,mutation_id") for i in [0,1]]
        assert all(row['is_done'] and not row['failed'] for side in report['mutations'] for row in side),'unfinished/failed final mutation'
        report['populations']=[replica(i,'SELECT (SELECT count() FROM analytics.events_raw) AS physical,(SELECT count() FROM analytics.events_canonical) AS canonical,(SELECT count() FROM analytics.events_resolved) AS public') for i in [0,1]]
        report['status']='passed'
        (root/'report.private.json').write_text(json.dumps(report,indent=2))
        print('Replicated runtime case passed: '+str(args.case)+'; native integration and behavioral assertions verified.',file=sys.stderr,flush=True)


if __name__=='__main__':
    main()
