"""Retained diagnostic classification, reconstruction and public HTTP proof."""
import json
import subprocess
import time
import urllib.request
from pathlib import Path

ACCOUNT = 'diagnostic-upgrade'


def seed(query):
    # Keep an expired raw fact physically present; logical retention must exclude it.
    # Replicated fixtures use the supported writer contract: synchronous full quorum.
    query("INSERT INTO analytics.retention_policy(singleton,revision,cutoff) VALUES (1,99,toDateTime64('2026-07-01',3,'UTC'))")
    base=dict(account_id=ACCOUNT,source='web',source_service='shop',session_id='retained',received_at='2026-07-01 12:01:00.000',url='https://example.com/one',properties={},context={})
    facts=[dict(base,event_id='upgrade-page',event_name='page_view',occurred_at='2026-07-01 12:00:00.000'),dict(base,event_id='upgrade-vital',event_name='web_vital',schema_version=1,properties={'metric':'LCP','value':1234},occurred_at='2026-07-01 12:00:20.000'),dict(base,event_id='expired-error',event_name='client_error',session_id='expired',occurred_at='2026-06-30 23:00:00.000')]
    query('INSERT INTO analytics.events_raw FORMAT JSONEachRow\n'+'\n'.join(json.dumps(fact) for fact in facts))


def observation(query):
    sql=f"""SELECT count() AS sessions,sum(page_count) AS pages,sum(engagement_count) AS engagement,sum(page_count=1 AND engagement_count=0) AS bounces,sum(dateDiff('millisecond',start,finish))/1000 AS duration FROM (SELECT session_id,minMerge(started) AS start,maxMerge(ended) AS finish,uniqExactIfMerge(page_ids) AS page_count,uniqExactIfMerge(engagement_ids) AS engagement_count FROM analytics.sessions WHERE account_id='{ACCOUNT}' GROUP BY source_service,session_id) FORMAT JSONEachRow"""
    value=query(sql)
    return json.loads(value) if isinstance(value,str) else value[0]


def expected(engagement):
    return dict(sessions=1,pages=1,engagement=engagement,bounces=1-engagement,duration=20)


def insert_after(query):
    query(f"""INSERT INTO analytics.events_raw(event_id,event_name,source,source_service,account_id,session_id,occurred_at,received_at,properties,context) VALUES ('upgrade-error','client_error','web','shop','{ACCOUNT}','retained',toDateTime64('2026-07-01 12:00:10',3,'UTC'),toDateTime64('2026-07-01 12:00:21',3,'UTC'),'{{"message":"synthetic","type":"Error","handled":false}}','{{}}')""")


def repair_args(status, operation, selected=False):
    report=status['result']['report']
    migration=next(m for m in report['migrations'] if m['definition']['migration']=='0026_diagnostic_session_engagement')
    args=['repair',operation,'--expect-position',report['observation']['position'],'--attempt',migration['attempt']]
    if selected:
        step=next(s for s in migration['steps'] if s['state'] in ('uncertain','observed-failure'))['attempt']
        args+=['--step-attempt',step['ownerAttempt'],'--step',step['step'],'--query-id',step['queryId']]
    return args


def public(h, server):
    from isolated_clickhouse import free_port
    from clickhouse_coordination_acceptance import eventually, stop
    key=h.run([h.admin,'issue-key','--kind','service','--account',ACCOUNT,'--description','owned diagnostic proof']).stdout.splitlines()[-2]
    port=free_port()
    with (h.root/'public-session.private').open('w') as output:
        service=subprocess.Popen([server],env=dict(h.env,KANSOKU_SERVER_PORT=str(port),KANSOKU_QUEUE_NAME='diagnostic_upgrade',OTEL_SDK_DISABLED='true'),stdout=output,stderr=output)
    base='http://127.0.0.1:'+str(port)
    try:
        def ready():
            assert service.poll() is None
            try:return urllib.request.urlopen(base+'/health/ready',timeout=2).status==200
            except OSError:return False
        eventually(ready,'diagnostic public readiness')
        def get(path):
            with urllib.request.urlopen(urllib.request.Request(base+path,headers={'Authorization':'Bearer '+key}),timeout=10) as response:
                return json.load(response)
        prefix='/metrics/sessions?from=2026-07-01&to=2026-07-02&timeGrain=none&measure='
        for measure,value in [('count',1),('bounce_rate',1),('average_duration_seconds',20)]:
            result=get(prefix+measure)
            assert result['points'][0]['value']==value, result
        # Diagnostics are still ordinary counted events.
        events=get('/metrics/events?from=2026-07-01&to=2026-07-02&timeGrain=none')
        assert sum(p['value'] for p in events['points'])==3, events
        h.sql(f"""INSERT INTO analytics.events_raw(event_id,event_name,source,source_service,account_id,session_id,occurred_at,received_at,properties,context) VALUES ('upgrade-purchase','purchase','web','shop','{ACCOUNT}','retained',toDateTime64('2026-07-01 12:00:30',3,'UTC'),toDateTime64('2026-07-01 12:00:31',3,'UTC'),'{{}}','{{}}')""")
        for measure,value in [('bounce_rate',0),('average_duration_seconds',30)]:
            result=get(prefix+measure)
            assert result['points'][0]['value']==value,result
    finally:
        stop(service)


def direct_case(root,native,proof,pg_migrate,admin,server,owned,FaultProxy):
    with owned(root,native,proof,pg_migrate,admin) as h:
        h.begin()
        h.entry(['--proof-historical-prefix','up','--initialize-ledger',h.env['KANSOKU_CH_MIGRATION_LEDGER_ID']],binary=proof)
        seed(h.sql)
        assert observation(h.sql)==expected(1)
        h.drain()
        proxy=FaultProxy(h.endpoint)
        proxy.match=b'TRUNCATE TABLE analytics.sessions'
        try:
            h.env['KANSOKU_CH_MIGRATION_ENDPOINT']=proxy.endpoint
            h.up(success=False,drain=False)
            assert proxy.triggered.is_set(), 'Failure must follow completed clear and precede replay'
        finally:
            proxy.close();h.env['KANSOKU_CH_MIGRATION_ENDPOINT']=h.endpoint
        assert h.sql('SELECT count() FROM analytics.sessions').strip()=='0'
        assert h.run(['psql','-XAt','-c','SELECT count(*) FROM kansoku.maintenance_fence WHERE active_migration_session IS NOT NULL']).stdout.strip()=='1'
        h.run(['psql','-XAt','-v','ON_ERROR_STOP=1','-c','SELECT kansoku.require_traffic_lock()'],success=False)
        h.run([admin,'apply-retention','--confirm'],success=False)
        h.up(success=False)
        h.finish(success=False)
        h.entry(['maintenance','reconcile'],success=False)
        def status():return json.loads(h.run([native,'status','--guarded','--json']).stdout)
        h.observed_entry(repair_args(status(),'accept-step',True),expected_sql=0,binary=native)
        h.entry(repair_args(status(),'resume'))
        assert observation(h.sql)==expected(0)
        insert_after(h.sql)
        assert observation(h.sql)==expected(0)
        h.observed_entry(['up'],expected_sql=0)
        h.finish()
        # Clear and repeat the same authored replay to prove old block identities
        # cannot suppress reconstruction. This is an owned explicit second window.
        h.begin()
        h.drain()
        replay=Path('kansoku-server/migrations/clickhouse/steps/0026_diagnostic_session_engagement/rebuild-sessions.sql').read_text()
        for _ in range(2):
            h.sql('TRUNCATE TABLE analytics.sessions')
            h.sql(replay)
            assert observation(h.sql)==expected(0)
        h.finish()
        public(h,server)
    return 1
