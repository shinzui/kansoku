"""Exercise the documented ordinary workflow from clean local clones, without SQL seeds."""
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from isolated_clickhouse import free_port
from test_support import execute

REPO=Path(__file__).resolve().parent.parent
# Previously accepted consumer: mori://shinzui/kansoku-ts/packages/kansoku-js.
PREVIOUS_SDK='0a4eea715b5f34fad8593e3dfd123ce407976c95'


def main():
    os.umask(0o077)
    signal.signal(signal.SIGTERM,lambda *_: (_ for _ in ()).throw(RuntimeError("ordinary workflow interrupted")))
    sdk_source=os.environ['KANSOKU_SDK_PROJECT']
    evidence=Path(tempfile.mkdtemp(prefix='first-use-',dir=REPO / '.dev/acceptance'))
    # Unix socket paths must remain below the OS path-length limit. This is a
    # clean checkout, not a database fixture or a copy of the developer's state.
    root=Path(tempfile.mkdtemp(prefix='ks-first-use-')).resolve()
    print('Private ordinary first-use evidence: '+str(evidence),flush=True)
    (evidence / 'clones.json').write_text(json.dumps(dict(root=str(root),previous_sdk=PREVIOUS_SDK))+'\n')
    clone=root/'server'
    sdk=root/'previous-sdk'
    sequence=0
    keys=[]
    def run(command,env=None,cwd=None,timeout=600):
        nonlocal sequence
        sequence+=1
        result=execute(command,env=env,cwd=cwd or clone,timeout=timeout)
        (evidence/f'command-{sequence}.private').write_text(result.stdout+result.stderr)
        assert result.returncode==0, f'ordinary workflow command {sequence} failed; private evidence retained'
        return result.stdout
    run(['git','clone','--no-hardlinks',str(REPO),str(clone)],cwd=root)
    run(['git','clone','--no-hardlinks',sdk_source,str(sdk)],cwd=root)
    run(['git','checkout','--detach',PREVIOUS_SDK],cwd=sdk)
    initial=run(['nix','develop','-c','bash','-c','eval "$shellHook"; python3 -c \'import os,json; print("KANSOKU_ENV_"+json.dumps(dict(os.environ)))\''],timeout=600)
    env=json.loads(next(line.removeprefix('KANSOKU_ENV_') for line in initial.splitlines() if line.startswith('KANSOKU_ENV_')))
    for key in list(env):
        if key.startswith(('KANSOKU_','OTEL_')):env.pop(key)
    env.update(PGPORT=str(free_port()),CLICKHOUSE_TCP_PORT=str(free_port()),CLICKHOUSE_HTTP_PORT=str(free_port()),
        PC_PORT_NUM=str(free_port()),PC_ADDRESS='127.0.0.1',PC_DISABLE_TUI='1',
        KANSOKU_SERVER_PORT=str(free_port()),OTEL_SDK_DISABLED='true')
    # Honor the clone's shipped shellHook-owned paths, never ambient databases.
    assert Path(env['PGDATA']).resolve().is_relative_to(clone)
    assert Path(env['CLICKHOUSE_HOME']).resolve().is_relative_to(clone)
    base='http://127.0.0.1:'+env['KANSOKU_SERVER_PORT']
    @contextmanager
    def running(command,name):
        with (evidence/(name+'.private')).open('w') as log:
            process=subprocess.Popen(command,cwd=clone,env=env,stdout=log,stderr=log,start_new_session=True)
        with (evidence/'processes.jsonl').open('a') as inventory:
            inventory.write(json.dumps(dict(pid=process.pid,name=name))+'\n')
        try:yield process
        finally:
            try:os.killpg(process.pid,signal.SIGTERM)
            except ProcessLookupError:pass
            deadline=time.monotonic()+45
            while time.monotonic()<deadline:
                process.poll()
                try:os.killpg(process.pid,0)
                except ProcessLookupError:break
                time.sleep(.1)
            else:
                try:os.killpg(process.pid,signal.SIGKILL)
                except ProcessLookupError:pass
            process.wait()
            if name.endswith('stack'):
                status=subprocess.run(['pg_ctl','status','-D',env['PGDATA']],env=env,capture_output=True)
                if status.returncode==0:
                    subprocess.run(['pg_ctl','stop','-D',env['PGDATA'],'-m','fast','-w'],env=env,capture_output=True,timeout=30)
                    raise AssertionError('ordinary stack shutdown left its owned PostgreSQL running')
    def wait(check,label,process=None,seconds=90):
        deadline=time.monotonic()+seconds
        while time.monotonic()<deadline:
            if process is not None:assert process.poll() is None,label+' exited'
            try:
                if check():return
            except (OSError,AssertionError,subprocess.CalledProcessError,subprocess.TimeoutExpired):pass
            time.sleep(.3)
        raise AssertionError('ordinary workflow timed out: '+label)
    def ready():
        return urllib.request.urlopen(base+'/health/ready',timeout=2).status==200
    def databases_ready():
        pg=subprocess.run(['psql','-Atc','SELECT 1'],env=env,capture_output=True,timeout=3).returncode==0
        ch=subprocess.run(['clickhouse-client','--host','127.0.0.1','--port',env['CLICKHOUSE_TCP_PORT'],'--query','SELECT 1'],env=env,capture_output=True,timeout=3).returncode==0
        return pg and ch
    native_initialized = False
    def migrate(native_only=False):
        nonlocal native_initialized
        if not native_only:
            run(['just','migrate'],env=env,timeout=1200)
        def ch(query):
            return run(['clickhouse-client','--host','127.0.0.1','--port',env['CLICKHOUSE_TCP_PORT'],'--query',query],env=env).strip()
        if 'KANSOKU_CH_MIGRATION_LEDGER_ID' not in env:
            assert Path(ch("SELECT value FROM system.server_settings WHERE name='path'")).resolve() == Path(env['CLICKHOUSE_HOME']).resolve()
            env.update(KANSOKU_CH_MIGRATION_TARGET='kansoku/first-use-' + uuid.uuid4().hex,
                KANSOKU_CH_MIGRATION_ENDPOINT='http://127.0.0.1:' + env['CLICKHOUSE_HTTP_PORT'],
                KANSOKU_CH_MIGRATION_SERVER_ID=ch('SELECT toString(serverUUID())'),
                KANSOKU_CH_MIGRATION_LEDGER_ID=str(uuid.uuid4()),KANSOKU_CLICKHOUSE_HOST='127.0.0.1',
                KANSOKU_CLICKHOUSE_USER='default',KANSOKU_CLICKHOUSE_PASSWORD='')
            (evidence / 'native-target.private.json').write_text(json.dumps({key:value for key,value in env.items() if key.startswith('KANSOKU_CH_MIGRATION_')}))
        audit=['--expect-target',env['KANSOKU_CH_MIGRATION_TARGET'],'--actor','ordinary first-use owner','--reason','owned clone initialization or native repeat']
        def cli(*args):
            return json.loads(run(['just','ch-migrate',*args],env=env,timeout=1200))
        session=cli('maintenance','begin','--json',*audit)['result']
        env['KANSOKU_CH_MIGRATION_SESSION']=session['id']
        def drain():
            # Every SDK producer subprocess has exited and no app server scope
            # is running here. Restart the actually owned process-compose server
            # with its retained data root before attesting the next entry.
            run(['process-compose','--address',env['PC_ADDRESS'],'--port',env['PC_PORT_NUM'],'process','restart','clickhouse'],env=env)
            wait(databases_ready,'same-root native restart')
            assert ch('SELECT toString(serverUUID())')==env['KANSOKU_CH_MIGRATION_SERVER_ID']
            status=cli('maintenance','status','--json')['result']
            reference=evidence/f'native-drain-{sequence}.private.json'
            reference.write_text(json.dumps(dict(session=session['id'],predecessor=status['entry'],server=env['KANSOKU_CH_MIGRATION_SERVER_ID'],ledger=env['KANSOKU_CH_MIGRATION_LEDGER_ID'],procedure='all owned clients stopped; process-compose restarted the same data root')))
            return ['--predecessor',str(status['entry'])],['--quiescent','--evidence',str(reference)]
        predecessor,quiet=drain()
        up=['up','--json',*audit,*quiet]
        if not native_initialized:
            up+=['--initialize-ledger',env['KANSOKU_CH_MIGRATION_LEDGER_ID']]
        report=cli(*predecessor,*up)['result']['report']
        expected=0 if native_initialized else 257
        assert len(report['observations'])==expected
        native_initialized=True
        cli('verify','--require-current','--guarded','--json')
        predecessor,quiet=drain()
        cli(*predecessor,'maintenance','finish','--json',*audit,*quiet)
        return report
    def request(path,body=None):
        headers={'Authorization':'Bearer '+(keys[0] if body is not None else keys[1])}
        if body is not None:headers['Content-Type']='application/json'
        with urllib.request.urlopen(urllib.request.Request(base+path,headers=headers,data=None if body is None else json.dumps(body).encode()),timeout=10) as response:
            return json.load(response)
    today=datetime.now(timezone.utc).date()
    query='/metrics/events?'+urllib.parse.urlencode(dict(**{'from':str(today),'to':str(today+timedelta(days=1))},filter=json.dumps(dict(dimension='source_service',op='eq',value='ordinary-first-use'))))
    def count():return sum(point['value'] for point in request(query)['points'])
    run(['nix','develop','-c','bun','install','--frozen-lockfile'],cwd=sdk)
    run(['nix','develop','-c','just','build'],cwd=sdk)
    runner=root/'previous-sdk-producer.ts'
    runner.write_text('''import assert from "node:assert/strict";
import {pathToFileURL} from "node:url";
const {createKansoku}=await import(pathToFileURL(process.env.KANSOKU_PREVIOUS_DIST!).href);
let batch:unknown;
const client=createKansoku({baseUrl:process.env.KANSOKU_FIRST_URL!,writeKey:process.env.KANSOKU_FIRST_KEY!,sourceService:"ordinary-first-use",autoStart:false,storage:"memory",persistQueue:false,autocapture:{pageViews:false,sessions:false,pageLeave:false},beforeSend:(event:any)=>({...event,url:event.properties.url}),fetch:async(url:any,init:any)=>{batch=JSON.parse(init.body);return fetch(url,init)}});
client.track("page_view",{url:"https://ordinary.example.test/first-use"});await client.shutdown();assert.equal(client.stats.accepted,1);assert.equal(client.stats.dropped,0);console.log(JSON.stringify(batch));
''')
    def produce():
        settings=dict(env,KANSOKU_PREVIOUS_DIST=str(sdk/'packages/kansoku-js/dist/index.js'),KANSOKU_FIRST_URL=base,KANSOKU_FIRST_KEY=keys[0])
        return json.loads(run(['nix','develop','-c','bun',str(runner)],env=settings,cwd=sdk).strip().splitlines()[-1])
    with running(['just','up'],'first-stack') as stack:
        wait(databases_ready,'fresh dependency startup',stack)
        actual=run(['psql','-Atc','SHOW data_directory'],env=env).strip()
        assert Path(actual).resolve()==Path(env['PGDATA']).resolve()
        migrate()
        repeated=migrate(native_only=True)
        assert repeated['observations']==[]
        for kind in ('write','service'):
            output=run(['just','issue-key',kind,'ordinary-first-use','fresh clone'],env=env)
            keys.append(re.search(r'ksk_[ws]_[A-Za-z0-9_-]+',output)[0])
        with running(['just','run'],'first-server') as server:
            wait(ready,'first server',server,seconds=1200)
            first=produce()
            wait(lambda:count()==1,'first consumer projection',server)
            assert request('/v1/batch',first)==dict(accepted=1,rejected=[])
            run(['process-compose','--address',env['PC_ADDRESS'],'--port',env['PC_PORT_NUM'],'process','stop','clickhouse'],env=env)
            second=produce()
            assert second[0]['eventId']!=first[0]['eventId']
            queued=int(run(['psql','-Atc',"SELECT count(*) FROM pgmq.q_kansoku_events"],env=env).strip())
            assert queued>=1,'accepted event did not survive in the durable queue'
    with running(['just','up'],'reused-stack') as stack:
        wait(databases_ready,'reused dependency startup',stack)
        migrate()
        with running(['just','run'],'reused-server') as server:
            wait(ready,'reused server',server,seconds=1200)
            wait(lambda:count()==2,'queued event recovery',server)
            assert request('/v1/batch',first)==dict(accepted=1,rejected=[])
            assert request('/v1/batch',second)==dict(accepted=1,rejected=[])
            wait(lambda:count()==2,'stable duplicate count after restart',server)
            time.sleep(1)
            assert count()==2
    report=dict(result='passed',cases=4,skipped=0,server_commit=run(['git','rev-parse','HEAD']).strip(),previous_sdk_commit=PREVIOUS_SDK,previous_sdk_source='mori://shinzui/kansoku-ts/packages/kansoku-js',
        workflow='fresh clone, qualified default shell, PostgreSQL-first setup, retained native identities and sessions, real same-root drain, explicit initialization/finish, zero-SQL native repeats, old SDK ingest, duplicate retry and queued outage recovery',clone=str(clone))
    (evidence/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Ordinary fresh-clone adoption/reuse/recovery: 4 cases, 0 skipped, passed.',flush=True)


if __name__=='__main__':main()
