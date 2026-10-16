#!/usr/bin/env python3
"""Public cohort roundtrips against owned PostgreSQL and ClickHouse."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
from acceptance_resources import OwnedResources
from enrichment_acceptance import event, eventually, send
from traits_acceptance import report


def verify_cohorts(base, write_key, token, other_token, erase_user=None, large_upload=False, after_membership=None):
    prefix = 'cohort_' + uuid.uuid4().hex
    def api(path, body=None, method='GET', credential=token, expected=200, **params):
        url = base + path + ('?' + urllib.parse.urlencode(params, doseq=True) if params else '')
        req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method,
                                    headers={'Authorization': 'Bearer ' + credential, 'Content-Type': 'application/json'})
        try:
            response = urllib.request.urlopen(req, timeout=40)
        except urllib.error.HTTPError as error:
            response = error
        value = json.load(response)
        assert response.code in (expected if isinstance(expected, tuple) else (expected,)), (path, response.code, value)
        return value
    with OwnedResources(api, token, after_membership) as api:
        def f(dimension, value, op='eq'):
            return dict(dimension=dimension, op=op, value=value)
        def create(name, conditions=None, **extra):
            return api('/cohorts',dict(name=prefix+name,kind='behavioural',conditions=conditions or [condition],**extra),'POST')
        condition = dict(did='feature_used',atLeast=3,withinDays=30,filters=[f('prop:feature',prefix)])
        rows=[]
        for user,count in [('A',3),('B',1),('C',3)]:
            for n in range(count):
                row=event(prefix+user+str(n),prefix+user,name='feature_used',timestamp=f'2026-07-01T00:00:0{n}Z')
                row.update(userId=prefix+user,anonymousId=prefix+user+'cookie',sourceService=prefix,properties={'feature':prefix})
                if user == 'A' and n == 0:
                    row.pop('userId')
                rows.append(row)
            # Whole-session reporting also contains a page, exposure and funnel.
            for name,props in [('page_view',{'url':'https://example.test/'}),('signup_started',{}),('signup_completed',{}),('payment_completed',{'amount':7}),('experiment_viewed',{'experiment':prefix,'variant':'a'})]:
                row=event(prefix+user+name,prefix+user,name=name,timestamp='2026-07-01T00:00:04Z')
                row.update(userId=prefix+user,sourceService=prefix,properties=props)
                rows.append(row)
        cancel=event(prefix+'cancel',prefix+'C',name='subscription_cancelled',timestamp='2026-07-01T00:00:05Z')
        cancel.update(userId=prefix+'C',sourceService=prefix)
        rows.append(cancel)
        # Occurrences before the lookback and at its exclusive upper bound do not count.
        for stamp,count in [('2026-05-01T00:00:00Z',3),('2026-07-03T00:00:00Z',2)]:
            for n in range(count):
                row=event(prefix+stamp+str(n),prefix+'B',name='feature_used',timestamp=stamp)
                row.update(userId=prefix+'B',sourceService=prefix,properties={'feature':prefix})
                rows.append(row)
        after=event(prefix+'after',prefix+'A',name='subscription_cancelled',timestamp='2026-07-03T00:00:00Z')
        after.update(userId=prefix+'A',sourceService=prefix)
        rows.append(after)
        # Native JSON cannot confer governed trait eligibility; public acceptance does.
        trait=event(prefix+'trait',prefix+'A',name='identify',timestamp='2026-07-01T00:00:06Z')
        trait.update(userId=prefix+'A',anonymousId=prefix+'Acookie',sourceService=prefix,schemaVersion=2,properties={'plan':prefix})
        rows.append(trait)
        for i in range(0,len(rows),3):
            send(base,write_key,rows[i:i+3])
        for i in range(0,len(rows),3):
            send(base,write_key,rows[i:i+3])
        foreign=event(prefix+'foreign',prefix+'foreign',name='feature_used',timestamp='2026-07-01T00:00:00Z')
        foreign.update(userId=prefix+'A',sourceService=prefix,properties={'feature':prefix})
        send(base,other_token,[foreign])
        cohort=create('power')
        ident=cohort['id']
        assert api('/cohorts/'+ident)['definition']['name']==prefix+'power'
        source_filter=json.dumps(f('source_service',prefix))
        selected=json.dumps(f('cohort',ident))
        def metric(endpoint='users', filters=None, **args):
            base_filters = [] if args.get('mode') == 'strict' else [source_filter]
            return report(base,token,endpoint,filter=base_filters+(filters if filters is not None else [selected]),to='2026-07-03',**args)
        def total(endpoint='users',**args):
            return sum(p['value'] for p in metric(endpoint,**args))
        eventually(lambda: total()==2)
        assert total(filters=[json.dumps(f('cohort',ident,'neq'))])==1
        assert total(filters=['cohort:eq:'+ident])==2
        groups=metric(filters=[],groupBy='cohort:'+ident)
        assert {p['group']['cohort:'+ident]:p['value'] for p in groups}=={'in':2,'out':1}
        assert sum(p['value'] for p in groups)==total(filters=[])
        for endpoint,args in [('events',{}),('page-views',{}),('revenue',{}),('feature-adoption',{}),('sessions',{}),('acquisition',{}),('users',{'window':'rolling7'}),('stickiness',{}),('lifecycle',{}),('retention',{'days':'1'}),('funnel',{'steps':'signup_started,signup_completed'}),('funnel',{'steps':'signup_started,signup_completed','mode':'strict'}),('conversion',{})]:
            metric(endpoint,**args)
            metric(endpoint,filters=[],groupBy='cohort:'+ident,**args)
        # Experiment routes deliberately reject arbitrary event filters.
        for endpoint,args in [('experiments',{'experiment':prefix}),('experiments',{'experiment':prefix,'measure':'diagnostics'}),('experiments/conversion',{'experiment':prefix,'event':'payment_completed'}),('experiments/funnel',{'experiment':prefix,'steps':'signup_started,signup_completed'})]:
            result=report(base,token,endpoint,filter=[selected],to='2026-07-03',**args)
            assert result
            assert report(base,token,endpoint,groupBy='cohort:'+ident,to='2026-07-03',**args)
        changed=dict(cohort['definition'],conditions=[condition,dict(didNot='subscription_cancelled',withinDays=90)])
        api('/cohorts/'+ident,changed,'PUT')
        assert total()==1
        # Pure negative/zero-count definitions retain users with no matching events.
        for label,rule in [('zero',dict(did=prefix+'never',atMost=0,withinDays=30)),('negative',dict(didNot=prefix+'never',withinDays=30))]:
            temporary=create(label,[rule])
            assert total(filters=[json.dumps(f('cohort',temporary['id']))])==3
            api('/cohorts/'+temporary['id'],method='DELETE')
        window=dict(from_='2026-07-01',to='2026-07-03')
        window['from']=window.pop('from_')
        assert api('/cohorts/'+ident+'/size',**window)=={'size':1}
        members=api('/cohorts/'+ident+'/members',**window)
        assert [e['node'] for e in members['edges']]==[prefix+'A']
        for invalid in [dict(changed,conditions=[condition]*5),dict(changed,conditions=[dict(condition,withinDays=400)]),dict(changed,traits=[f('user:missing','x')])]:
            assert api('/cohorts',invalid,'POST',expected=400)['code']=='invalid_cohort'
        traits=create('trait',traits=[f('user:plan',prefix)])
        assert api('/cohorts/'+traits['id']+'/size',**window)=={'size':1}
        # Stored and query references hide another account's definitions.
        assert api('/cohorts/'+ident,credential=other_token,expected=404)['code']=='cohort_not_found'
        assert api('/metrics/users',credential=other_token,expected=404,filter=selected,**window)['code']=='cohort_not_found'
        assert api('/cohorts/'+ident,changed,'PUT',credential=other_token,expected=404)['code']=='cohort_not_found'
        static=api('/cohorts',dict(name=prefix+'static',kind='static'),'POST')
        sid=static['id']
        path='/cohorts/'+sid+'/members'
        assert api(path,dict(userIds=[prefix+'A',prefix+'B']),'PUT')=={'size':2}
        first=api(path,first=1,**window)
        second=api(path,first=1,after=first['pageInfo']['endCursor'],**window)
        assert [e['node'] for e in first['edges']+second['edges']]==[prefix+'A',prefix+'B']
        assert first['pageInfo']['hasNextPage'] and not first['pageInfo']['hasPreviousPage']
        assert not second['pageInfo']['hasNextPage'] and second['pageInfo']['hasPreviousPage']
        back=api(path,last=1,before=second['pageInfo']['startCursor'],**window)
        assert back['edges']==first['edges']
        assert api(path,dict(userIds=[prefix+'B']),'PUT')=={'size':1}
        assert api('/cohorts/'+sid+'/size',**window)=={'size':1}
        assert [e['node'] for e in api(path,**window)['edges']]==[prefix+'B']
        assert total(filters=[json.dumps(f('cohort',sid))])==1
        assert total(filters=[json.dumps(f('cohort',sid.upper()))])==1
        assert api(path,first=101,expected=400,**window)['code']=='page_size_too_large'
        assert api(path,after=first['edges'][0]['cursor']+'!',expected=400,**window)['code']=='invalid_cursor'
        # Walk definitions both ways; replay pages and verify edge cursor consistency.
        def walk(backward=False):
            output=[]; cursor=None
            while True:
                args={'last' if backward else 'first':1}
                if cursor: args['before' if backward else 'after']=cursor
                page=api('/cohorts',**args)
                assert page==api('/cohorts',**args)
                edges=page['edges']; info=page['pageInfo']
                assert info['startCursor']==(edges[0]['cursor'] if edges else None)
                assert info['endCursor']==(edges[-1]['cursor'] if edges else None)
                output=edges+output if backward else output+edges
                if not info['hasPreviousPage' if backward else 'hasNextPage']: break
                cursor=info['startCursor' if backward else 'endCursor']
            return [e['node']['id'] for e in output]
        assert walk()==walk(True)==sorted([ident,traits['id'],sid])
        assert api('/cohorts',after=first['pageInfo']['endCursor'],expected=400)['code']=='invalid_cursor'
        if large_upload:
            large=api('/cohorts',dict(name=prefix+'large',kind='static'),'POST')['id']
            large_path='/cohorts/'+large+'/members'
            ids=['member_'+str(i).zfill(5) for i in range(50000)]
            assert api(large_path,dict(userIds=ids),'PUT')=={'size':50000}
            assert api(large_path,dict(userIds=ids),'PUT')=={'size':50000}
            assert api('/cohorts/'+large+'/size',**window)=={'size':50000}
            assert len(api(large_path,first=100,**window)['edges'])==100
            assert api(large_path,dict(userIds=[]),'PUT')=={'size':0}
            assert api('/cohorts/'+large+'/size',**window)=={'size':0}
            api('/cohorts/'+large,method='DELETE')
            print('Cohort 50000-member replacement, retry and clear: passed.',flush=True)
        assert api('/cohorts/'+ident,method='DELETE') is True
        assert api('/metrics/users',expected=404,filter=selected,**window)['code']=='cohort_not_found'
        if erase_user:
            erase_user(prefix+'B')
            assert api('/cohorts/'+sid+'/size',**window)=={'size':0}
            assert api('/cohorts/'+sid+'/members',**window)['edges']==[]
        assert api('/cohorts/'+sid+'/members',dict(userIds=[]),'PUT')=={'size':0}
        api('/cohorts/'+sid,method='DELETE')
        api('/cohorts/'+traits['id'],method='DELETE')
        verify_organization_conditions(base, write_key, token, other_token, api, prefix+'org_')
        print('Cohorts: CRUD, validation, account isolation, all metric families, negative/trait membership, replay, static replacement, bidirectional pagination passed.',flush=True)


def verify_organization_conditions(base, write_key, token, other_token, api, prefix):
    """Exact person populations, including joins private to each event condition."""
    def term(dimension, value=None, op='eq'):
        return dict(dimension=dimension, op=op, **({} if op in ('set', 'unset') else {'value': value}))

    def row(key, user, name, organization=None, stamp='2026-07-01T00:00:00Z', properties=None, version=None):
        value = event(prefix+key, prefix+user, name=name, timestamp=stamp)
        value.update(userId=prefix+user, anonymousId=prefix+user+'cookie', sourceService=prefix, properties=properties or {})
        if organization:
            value['organizationId'] = prefix+organization
        if version:
            value['schemaVersion'] = version
        if user == 'anonymous':
            value.pop('userId')
        return value

    rows = []
    for user, organization, count in [('A', 'One', 2), ('B', 'One', 1), ('C', 'Two', 1), ('D', None, 1), ('E', None, 0), ('anonymous', 'One', 1)]:
        rows.append(row(user+'observed', user, prefix+'observed', organization if user != 'anonymous' else None))
        for n in range(count):
            rows.append(row(user+str(n), user, 'feature_used', organization,
                            stamp=f'2026-07-01T00:00:0{n+1}Z', properties={'feature': prefix}))
    groups = [row('groupOne', 'A', 'group', 'One', '2026-07-01T00:00:10Z', {'plan': 'pro', 'seats': 10}, 2),
              row('groupTwo', 'C', 'group', 'Two', '2026-07-01T00:00:11Z', {'plan': 'enterprise', 'seats': 2}, 2)]
    rows += groups
    rows.append(row('DunknownOrg', 'D', 'feature_used', 'NoTraits', properties={'feature': prefix}))
    rows.append(row('identifyA', 'A', 'identify', stamp='2026-07-01T00:00:12Z', properties={'plan': prefix}, version=2))
    # D's current membership must not fill its unstamped feature condition.
    rows.append(row('membershipD', 'D', 'group', 'One', '2026-07-04T00:00:00Z', version=2))
    # B's same session has later matching events. A widened session source must
    # not move the saved cohort's original exclusive upper bound.
    for n in range(2):
        rows.append(row('Bfuture'+str(n), 'B', 'feature_used', 'One', '2026-07-03T00:00:0'+str(n)+'Z', {'feature': prefix}))
    for start in range(0, len(rows), 3):
        send(base, write_key, rows[start:start+3])
    foreign = [dict(value, properties=dict(value['properties'])) for value in rows]
    for value in foreign:
        if value['eventName'] == 'group' and value['eventId'] == prefix+'groupOne':
            value['properties'] = {'plan': 'free', 'seats': 2}
        elif value['eventName'] == 'group' and value['eventId'] == prefix+'groupTwo':
            value['properties'] = {'plan': 'pro', 'seats': 10}
    for start in range(0, len(foreign), 3):
        send(base, other_token, foreign[start:start+3])

    dates = {'from': '2026-07-01', 'to': '2026-07-03'}
    # Bound negative/zero-count populations to this fixture's observed users.
    guard = dict(did=prefix+'observed', withinDays=30)
    pro = term('org:plan', 'pro')
    seats = term('org:seats', 5, 'gt')

    def condition(*terms, **extra):
        return dict(did='feature_used', withinDays=30, filters=[term('prop:feature', prefix), *terms], **extra)

    def definition(name, rule, **extra):
        return dict(name=prefix+name, kind='behavioural', conditions=[guard, rule], **extra)

    def create(name, rule, credential=token, **extra):
        return api('/cohorts', definition(name, rule, **extra), 'POST', credential=credential)['id']

    def members(ident, credential=token, **page):
        return api('/cohorts/'+ident+'/members', credential=credential, **dates, **page)

    def ids(ident, credential=token):
        return [edge['node'] for edge in members(ident, credential)['edges']]

    def exact(ident, users, credential=token):
        expected = [prefix+user for user in users]
        assert ids(ident, credential) == expected, (ident, ids(ident, credential), expected)
        assert api('/cohorts/'+ident+'/size', credential=credential, **dates) == {'size': len(users)}
        for backwards in (False, True):
            result, cursor = [], None
            while True:
                page = members(ident, credential, **({'last': 1} if backwards else {'first': 1}),
                               **({('before' if backwards else 'after'): cursor} if cursor else {}))
                part = [edge['node'] for edge in page['edges']]
                result = part+result if backwards else result+part
                info = page['pageInfo']
                if not info['hasPreviousPage' if backwards else 'hasNextPage']:
                    break
                cursor = info['startCursor' if backwards else 'endCursor']
            assert result == expected, (backwards, result, expected)

    ident = create('pro', condition(pro))
    # This is also the early native reproduction: creation followed by size and
    # exact member execution, rather than a string-only SQL assertion.
    eventually(lambda: ids(ident) == [prefix+'A', prefix+'B'])
    exact(ident, 'AB')
    foreign_id = create('foreign', condition(pro), credential=other_token)
    eventually(lambda: ids(foreign_id, other_token) == [prefix+'C'])
    exact(foreign_id, 'C', other_token)
    numeric = create('seats', condition(seats))
    exact(numeric, 'AB')
    api('/cohorts/'+numeric, definition('seats', condition(term('org:seats', 5, 'lt'))), 'PUT')
    exact(numeric, 'C')
    api('/cohorts/'+numeric, definition('seats', condition(seats)), 'PUT')
    exact(numeric, 'AB')
    foreign_numeric = create('foreignSeats', condition(seats), credential=other_token)
    exact(foreign_numeric, 'C', other_token)
    # Updating a newly created definition exercises the same supported compiler.
    updated = definition('pro', condition({'or': [term('prop:feature', prefix+'absent'), pro]}))
    api('/cohorts/'+ident, updated, 'PUT')
    exact(ident, 'AB')
    either_plan = create('either', condition({'or': [pro, term('org:plan', 'enterprise')]}))
    exact(either_plan, 'ABC')
    mixed = create('mixed', condition({'or': [term('org:plan', 'enterprise'), term('org:seats', 5, 'gt')]}))
    exact(mixed, 'ABC')
    for label, predicate, expected in [('set', term('org:plan', op='set'), 'ABC'),
                                        ('unset', term('org:plan', op='unset'), 'D'),
                                        ('notPro', term('org:plan', 'pro', 'neq'), 'C')]:
        exact(create(label, condition(predicate)), expected)
        # Direct user metrics also count the anonymous-only pro subject; saved
        # cohorts deliberately contain identified users only.
        points = report(base, token, 'users', filter=['source_service:eq:'+prefix, 'event_name:eq:feature_used', json.dumps(predicate)])
        assert sum(p['value'] for p in points) == len(expected)+(label == 'set'), (label, points)
    negative = condition(pro)
    negative['didNot'] = negative.pop('did')
    exact(create('negative', negative), 'CDE')
    exact(create('upper', condition(pro, atMost=1)), 'BCDE')
    exact(create('zero', condition(pro, atMost=0)), 'CDE')
    exact(create('userTrait', condition(pro), traits=[term('user:plan', prefix)]), 'A')
    frequent = create('frequent', condition(pro, atLeast=2))
    exact(frequent, 'A')

    def total(endpoint='users', cohort=ident, op='eq', **extra):
        points = report(base, token, endpoint, filter=['source_service:eq:'+prefix, 'event_name:eq:'+prefix+'observed',
                                                     json.dumps(term('cohort', cohort, op))], **extra)
        return sum(p['value'] for p in points)

    assert total() == 2
    # Anonymous-only subjects remain outside the cohort and inside its complement.
    assert total(op='neq') == 4
    assert total(aggregate='organizations') == 1
    assert total(aggregate='organizations', attribution='user_organization') == 1
    assert total(op='neq', aggregate='organizations') == 1
    assert total(op='neq', aggregate='organizations', attribution='user_organization') == 2
    session_points = report(base, token, 'sessions', filter=['source_service:eq:'+prefix, json.dumps(term('cohort', frequent))])
    assert sum(p['value'] for p in session_points) == 1, session_points
    saved = dict(name=prefix+'metric', description='organization-filtered people', eventNames=[prefix+'observed'],
                 aggregation='unique_count', filters=['cohort:eq:'+ident], groupBy=[], timeGrain='day')
    api('/metric-definitions', saved, 'POST')
    assert sum(p['value'] for p in report(base, token, 'custom', metric=saved['name'])) == 2

    for bad in [term('org:unknown', 'x'), term('org:seats', '5', 'contains'), term('user:plan', 'pro')]:
        invalid = definition('invalid', condition(bad))
        assert api('/cohorts', invalid, 'POST', expected=400)['code'] == 'invalid_cohort'
        assert api('/cohorts/'+ident, invalid, 'PUT', expected=400)['code'] == 'invalid_cohort'
    exact(ident, 'AB')
    later = row('groupLater', 'A', 'group', 'One', '2026-07-05T00:00:00Z', {'plan': 'free', 'seats': 1}, 2)
    send(base, write_key, [later])
    eventually(lambda: ids(ident) == [] and ids(numeric) == [])
    send(base, write_key, groups)
    # Wait for an ordinary marker after the replay so the final read proves the
    # replay has passed through the asynchronous writer.
    marker = row('replayed', 'E', prefix+'replayed')
    send(base, write_key, [marker])
    eventually(lambda: sum(p['value'] for p in report(base, token, 'events', filter=['event_name:eq:'+prefix+'replayed'])) == 1)
    exact(ident, '')
    exact(numeric, '')
    exact(either_plan, 'C')
    exact(foreign_id, 'C', other_token)
    assert total() == 0
    assert sum(p['value'] for p in report(base, token, 'custom', metric=saved['name'])) == 0
    print('Organization cohort conditions: exact members/pages, numeric/OR/null filters, complements, current traits/replay, account isolation, metrics and session bounds passed.', flush=True)


def main(verify=verify_cohorts, *, pass_environment=False):
    from contextlib import contextmanager
    import time
    import signal
    def interrupted(signum, frame):
        raise RuntimeError('cohort acceptance interrupted by signal '+str(signum))
    for signum in (signal.SIGTERM,signal.SIGINT):
        signal.signal(signum,interrupted)
    Path('.dev/acceptance').mkdir(parents=True,exist_ok=True)
    ROOT=Path(tempfile.mkdtemp(prefix='cohort-',dir=Path('.dev/acceptance'))).resolve()
    @contextmanager
    def child(command,env,name):
        with (ROOT/(name+'.log')).open('w') as log:
            process=subprocess.Popen(command,env=env,stdout=log,stderr=log)
            try: yield process
            finally:
                process.terminate()
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
    def run(command,env,name):
        result=subprocess.run(command,env=env,capture_output=True,text=True,timeout=60)
        (ROOT/(name+'.log')).write_text(result.stdout+result.stderr)
        result.check_returncode()
    def wait_for(process,check,label):
        for _ in range(300):
            assert process.poll() is None,(label,'exited')
            try:
                if check(): return
            except (OSError,urllib.error.URLError): pass
            time.sleep(.1)
        raise RuntimeError(label+' startup timed out')
    def request(base,path):
        return json.load(urllib.request.urlopen(base+path,timeout=2))
    def clean_environment():
        return {k:v for k,v in os.environ.items() if not k.startswith(('PG','CLICKHOUSE','KANSOKU_','OTEL_'))}
    from isolated_clickhouse import isolated_clickhouse,apply_migrations,free_port
    from test_support import binary
    env=clean_environment()
    pg=ROOT/'postgres'
    run(['initdb','-D',str(pg),'-A','trust','-U','postgres','--no-locale','--encoding=UTF8'],env,'cohort-init')
    port=free_port()
    server=os.environ.get('KANSOKU_COHORT_SERVER') or binary('kansoku-server:exe:kansoku-server')
    migrate=os.environ.get('KANSOKU_COHORT_MIGRATE') or binary('kansoku-server:exe:kansoku-migrate')
    if Path(server).parent.name == 'bin':
        env.update(KANSOKU_CH_MIGRATION_BINARY=str(Path(server).with_name('kansoku-ch-migrate')),KANSOKU_PG_MIGRATION_BINARY=migrate)
    with tempfile.TemporaryDirectory(prefix='ks-cohort-pg-') as socket:
        env.update(PGHOST=socket,PGPORT=str(port),PGUSER='postgres',PGDATABASE='postgres',PG_CONNECTION_STRING=f'host={socket} port={port} user=postgres dbname=postgres')
        with child(['postgres','-D',str(pg),'-k',socket,'-p',str(port),'-h','127.0.0.1'],env,'cohort-postgres') as process:
            wait_for(process,lambda: subprocess.run(['pg_isready'],env=env,capture_output=True).returncode==0,'PostgreSQL')
            actual = run(['psql','-XAtc','SHOW data_directory'],env,'cohort-pg-ownership').strip()
            assert Path(actual).resolve() == pg.resolve(), 'refusing an unowned cohort coordinator'
            env['KANSOKU_OWNED_POSTGRES_ROOT'] = str(pg.resolve())
            run([migrate,'up'],env,'cohort-pg-migrate')
            with isolated_clickhouse(directory=ROOT/'clickhouse') as native:
                native = dict(env, **{k:v for k,v in native.items() if k.startswith(('CLICKHOUSE','KANSOKU_CLICKHOUSE','KANSOKU_REQUIRED_INTEGRATION','KANSOKU_OWNED_CLICKHOUSE_'))})
                # Preserve the isolated ClickHouse coordinates when overlaying PostgreSQL.
                native.update(KANSOKU_QUEUE_NAME='cohort_acceptance',KANSOKU_WRITER_MAX_LATENCY_MS='100',KANSOKU_QUEUE_POLL_INTERVAL_SEC='1')
                apply_migrations(native)
                tokens=[]
                for kind,account in [('write','cohorts'),('service','cohorts'),('service','other')]:
                    result=subprocess.check_output([server,'issue-key','--kind',kind,'--account',account,'--description','cohort acceptance'],env=native,text=True)
                    tokens.append(result.splitlines()[-2])
                native['KANSOKU_SERVER_PORT']=str(free_port())
                base='http://127.0.0.1:'+native['KANSOKU_SERVER_PORT']
                with child([server],native,'cohort-server') as process:
                    wait_for(process,lambda: request(base,'/health/ready')['status']=='ok','server')
                    def erase_user(user):
                        result=subprocess.run([os.environ.get('KANSOKU_COHORT_ADMIN') or binary('kansoku-server:exe:kansoku-admin'),'erase-user','--account','cohorts','--user',user,'--out',str(ROOT/'erased.json'),'--confirm'],env=native,capture_output=True,text=True,timeout=90)
                        (ROOT/'cohort-erasure.log').write_text(result.stdout+result.stderr)
                        result.check_returncode()
                        assert json.loads(result.stdout)['stage']=='complete'
                    verify(base,*tokens,erase_user=erase_user,large_upload=True,**({"env": native} if pass_environment else {}))
                    if verify is verify_cohorts:
                        print('Cohort static member erasure: passed.',flush=True)
    print('Private resource evidence: '+str(ROOT),flush=True)


if __name__=='__main__': main()
