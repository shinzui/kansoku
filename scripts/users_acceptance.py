#!/usr/bin/env python3
"""Public identified-user reads against private, disposable real stores."""
import json
import urllib.parse
import urllib.request
import urllib.error
import uuid
import subprocess
import os
from pathlib import Path
from datetime import datetime, timezone
from enrichment_acceptance import event, eventually, send
from cohorts_acceptance import main


def verify_users(base, write_key, token, other_token, erase_user=None, **kwargs):
    prefix = 'users_' + uuid.uuid4().hex
    def api(path='/users', credential=token, expected=200, body=None, method='GET', **params):
        req = urllib.request.Request(base + path + ('?' + urllib.parse.urlencode(params, doseq=True) if params else ''), data=None if body is None else json.dumps(body).encode(), method=method, headers={'Authorization': 'Bearer '+credential,'Content-Type':'application/json'})
        try:
            response = urllib.request.urlopen(req, timeout=40)
        except urllib.error.HTTPError as error:
            response = error
        value = json.load(response)
        assert response.code == expected, (path, response.code, value)
        return value
    documented=json.loads((Path(__file__).resolve().parent.parent/'docs/api/openapi.json').read_text())
    served=api('/openapi.json')
    assert served==documented, 'served OpenAPI differs from committed contract'
    rows=[]
    for suffix, name, stamp in [('pre','feature_used','2026-07-01T00:00:00Z'),('id','identify','2026-07-02T00:00:00Z'),('action','feature_used','2026-07-02T00:00:01Z')]:
        row=event(prefix+suffix,prefix,name=name,timestamp=stamp)
        row.update(anonymousId=prefix+'cookie',sourceService=prefix,properties={'feature':prefix} if name=='feature_used' else {})
        if suffix!='pre': row['userId']=prefix+'A'
        else: row.pop('userId',None)
        rows.append(row)
    send(base,write_key,rows)
    def selected(**args): return api(search=prefix,**args)
    eventually(lambda: len(selected()['edges'])==1)
    node=selected()['edges'][0]['node']
    assert node['userId']==prefix+'A' and node['firstActivityAt'].startswith('2026-07-01'),node
    dates={'from':'2026-07-01','to':'2026-07-03'}
    counts=api('/users/activity-counts',**dates)
    metrics=api('/metrics/users',timeGrain='none',**dates)
    assert counts['identified']+counts['anonymous']==sum(p['value'] for p in metrics['points']), (counts,metrics)
    assert not api(credential=other_token,search=prefix)['edges']
    api(credential=write_key,expected=403)
    api(credential='',expected=401)
    for args in [{'search':''},{'order':'bad'},{'first':0},{'first':101},{'from':'2026-01-01'},{'wat':1},{'search':['a','b']},{'after':'bad'},{'from':'2026-07-03','to':'2026-07-01'},{'search':'a'*257}]:
        api(expected=400,**args)
    # Tied extrema, profile-only subjects and literal wildcard characters.
    more=[]
    for user in ['B','C','%_Mixed:colon']:
        row=event(prefix+user,prefix+user,name='identify' if user=='C' else 'feature_used',timestamp='2026-07-02T00:00:01Z')
        row.update(userId=prefix+user,anonymousId=prefix+user+'cookie',sourceService=prefix,properties={} if user=='C' else {'feature':prefix})
        more.append(row)
    send(base,write_key,more)
    eventually(lambda: len(selected()['edges'])==4)
    assert api(search='%_mixed')['edges'][0]['node']['userId']==prefix+'%_Mixed:colon'
    assert len(selected(**dates)['edges'])==3
    colon_id=prefix+'%_Mixed:colon'
    assert api('/users/'+urllib.parse.quote(colon_id,safe=''))['userId']==colon_id
    for order in ['lastActivity','firstActivity']:
        expected=[e['node']['userId'] for e in selected(order=order)['edges']]
        forward=[]; cursor=None
        while True:
            page=selected(order=order,first=1,**({'after':cursor} if cursor else {}))
            forward += [e['node']['userId'] for e in page['edges']]
            if not page['pageInfo']['hasNextPage']: break
            cursor=page['pageInfo']['endCursor']
        assert forward==expected,(forward,expected)
        backward=[]; cursor=None
        while True:
            page=selected(order=order,last=1,**({'before':cursor} if cursor else {}))
            backward=[e['node']['userId'] for e in page['edges']]+backward
            if not page['pageInfo']['hasPreviousPage']: break
            cursor=page['pageInfo']['startCursor']
        assert backward==expected,(backward,expected)
    assert selected()['edges'][-1]['node']['firstActivityAt'] is None
    wrong_order=selected(first=1)['pageInfo']['endCursor']
    selected(order='firstActivity',after=wrong_order,expected=400)
    person=prefix+'A'
    api(filter=[json.dumps({'or':[{'dimension':'user:plan','op':'eq','value':'pro'}]})],expected=400)
    profile_path='/users/'+urllib.parse.quote(person,safe='')
    observed=[]
    for eid,name,version,stamp,props in [
        ('set','identify',2,'2026-07-02T01:00:00Z',{'plan':'pro','company_size':0}),
        ('once','identify_once',1,'2026-07-03T01:00:00Z',{'plan':'loser','role':''}),
        ('legacy','identify',1,'2026-07-04T01:00:00Z',{'plan':'ineligible'}),
        ('group1','group',1,'2026-07-02T02:00:00Z',{}),
        ('group2','group',2,'2026-07-03T02:00:00Z',{'plan':'business','seats':10}),
        ('secret','feature_used',1,'2026-07-02T00:00:01Z',{'feature':prefix,'secret':prefix+'SECRET'}),
        ('tieZ','identify',2,'2026-07-02T01:00:00Z',{'signup_source':'winner'}),
        ('tieA','identify',2,'2026-07-02T01:00:00Z',{'signup_source':'loser'}),
    ]:
        row=event(prefix+eid,prefix,name=name,timestamp=stamp)
        row.update(userId=person,anonymousId=prefix+'cookie',sourceService=prefix,schemaVersion=version,properties=props,identifiers={'device':prefix+'DEVICE','email_hmac':prefix+'EMAIL'},context={'private':prefix+'CONTEXT'})
        if name=='group': row['organizationId']=prefix+('oldorg' if eid=='group1' else 'org')
        observed.append(row)
    for i in range(0,len(observed),2): send(base,write_key,observed[i:i+2])
    for i in range(0,len(observed),2): send(base,write_key,observed[i:i+2])
    eventually(lambda: api(profile_path)['traits'].get('plan',{}).get('value')=='pro' and api(profile_path)['retainedEventCount']==11)
    profile=api(profile_path)
    assert profile['traits']['plan']['operation']=='set'
    assert profile['traits']['plan']['observedAt'].startswith('2026-07-02T01:00:00')
    assert profile['traits']['role']['operation']=='set_once'
    assert profile['traits']['company_size']['value']==0
    assert profile['traits']['signup_source']['value']=='winner'
    assert profile['resolvedAnonymousCount']==1,profile
    assert profile['organization']['organizationId']==prefix+'org',profile
    assert profile['organization']['traits']=={'plan':'business','seats':10}
    assert set(profile['identityEvidence'])=={'cookie','device','fingerprint','email_hmac','email_sha256'}
    assert profile['identityEvidence']['device']==profile['identityEvidence']['email_hmac']==1
    assert profile['retainedEventCount']==11,profile
    summary=api(search=person)['edges'][0]['node']
    assert summary['traits']=={key:trait['value'] for key,trait in profile['traits'].items()}
    for sentinel in ['DEVICE','EMAIL','SECRET','CONTEXT']:
        assert prefix+sentinel not in json.dumps(profile)
    api(profile_path,credential=other_token,expected=404)
    api('/users/'+prefix+'absent',expected=404)
    # All supported typed trait operations, missing values and combined selectors.
    def filt(dimension,op,value=None):
        term={'dimension':dimension,'op':op}
        if op not in ['set','unset']: term['value']=value
        return json.dumps(term)
    for dimension,op,value,contains in [
        ('user:plan','eq','pro',True),('user:plan','neq','pro',False),
        ('user:plan','contains','r',True),('user:plan','in',['pro','other'],True),
        ('user:plan','set',None,True),('user:plan','unset',None,False),
        ('user:company_size','gt',-1,True),('user:company_size','lt',1,True),
    ]:
        assert bool(api(search=person,filter=[filt(dimension,op,value)])['edges'])==contains
    cohort=api('/cohorts',body={'name':prefix,'kind':'static'},method='POST')
    try:
        api('/cohorts/'+cohort['id']+'/members',body={'userIds':[person]},method='PUT')
        assert api(search=prefix,filter=[filt('cohort','eq',cohort['id']),filt('user:plan','eq','pro')])['edges'][0]['node']['userId']==person
        assert len(api(search=prefix,filter=[filt('cohort','neq',cohort['id'])])['edges'])==3
    finally: api('/cohorts/'+cohort['id'],method='DELETE')
    all_events=api(profile_path+'/events')['edges']
    assert len(all_events)==11 and len({e['node']['eventId'] for e in all_events})==11
    assert prefix+'pre' in {e['node']['eventId'] for e in all_events}
    for edge in all_events:
        assert 'eventReceivedAt' not in edge['node']
        assert set(edge['node'])=={'eventId','eventName','occurredAt','source','sourceService','sessionId','host','path','isPageView','properties'}
    assert next(e['node'] for e in all_events if e['node']['eventId']==prefix+'legacy')['properties']=={}
    assert next(e['node'] for e in all_events if e['node']['eventId']==prefix+'set')['properties']['plan']=='pro'
    public=json.dumps(all_events)
    for sentinel in ['DEVICE','EMAIL','SECRET','CONTEXT']: assert prefix+sentinel not in public
    forward=[]; cursor=None
    while True:
        page=api(profile_path+'/events',first=1,**({'after':cursor} if cursor else {}))
        forward+=page['edges']
        if not page['pageInfo']['hasNextPage']: break
        cursor=page['pageInfo']['endCursor']
    assert forward==all_events
    backward=[]; cursor=None
    while True:
        page=api(profile_path+'/events',last=1,**({'before':cursor} if cursor else {}))
        backward=page['edges']+backward
        if not page['pageInfo']['hasPreviousPage']: break
        cursor=page['pageInfo']['startCursor']
    assert backward==all_events
    assert len(api(profile_path+'/events',filter=[filt('event_name','in',['feature_used','unknown_valid'])])['edges'])==3
    assert not api(profile_path+'/events',filter=[filt('event_name','eq','unknown_valid')])['edges']
    for invalid in [filt('event_name','contains','feature'),filt('user:plan','eq','pro')]:
        api(profile_path+'/events',filter=[invalid],expected=400)
    # Behavioural membership sees the complete lookback beyond selected dates.
    behavioural=api('/cohorts',body={'name':prefix+'behaviour','kind':'behavioural','conditions':[{'did':'feature_used','atLeast':3,'withinDays':30,'filters':[{'dimension':'prop:feature','op':'eq','value':prefix}]}]},method='POST')
    try:
        selected_row=api(search=person,filter=[filt('cohort','eq',behavioural['id'])],**{'from':'2026-07-02','to':'2026-07-03'})['edges'][0]['node']
        assert selected_row['firstActivityAt'].startswith('2026-07-01')
        assert not api(search=person,filter=[filt('cohort','eq',behavioural['id'])])['edges']
    finally: api('/cohorts/'+behavioural['id'],method='DELETE')
    assert api('/users/activity-counts',**{'from':'1900-01-01','to':'1900-01-02'})=={'identified':0,'anonymous':0}
    anon=event(prefix+'anonymous',prefix+'anonymous',name='feature_used',timestamp='2026-07-01T00:00:00Z')
    anon.update(anonymousId=person,sourceService=prefix,properties={'feature':prefix})
    anon.pop('userId')
    send(base,write_key,[anon])
    bot=event(prefix+'bot',prefix+'bot',name='feature_used',timestamp='2026-07-01T00:00:00Z')
    bot.update(userId=prefix+'Bot',anonymousId='',sourceService=prefix,properties={'feature':prefix})
    send(base,write_key,[bot],agent='Googlebot/2.1 (+http://www.google.com/bot.html)')
    eventually(lambda: api('/users/activity-counts',**dates)['anonymous']>=1)
    conflict=event(prefix+'conflictBinding',prefix+'conflictBinding',name='identify',timestamp='2026-07-02T03:00:00Z')
    conflict.update(userId=prefix+'B',anonymousId=prefix+'Bcookie',identifiers={'device':prefix+'DEVICE'},sourceService=prefix,properties={})
    unresolved=event(prefix+'conflicted',prefix+'conflicted',name='feature_used',timestamp='2026-07-02T03:00:01Z')
    unresolved.pop('userId')
    unresolved.update(anonymousId=prefix+'CONFLICT_COOKIE',identifiers={'device':prefix+'DEVICE'},sourceService=prefix,properties={'feature':prefix})
    send(base,write_key,[conflict,unresolved])
    eventually(lambda: api('/users/'+prefix+'B')['identityEvidence']['device']==1)
    assert prefix+'conflicted' not in {e['node']['eventId'] for e in api(profile_path+'/events')['edges']}
    assert prefix+'conflicted' not in {e['node']['eventId'] for e in api('/users/'+prefix+'B'+'/events')['edges']}
    foreign=event(prefix+'foreign',prefix+'foreign',name='identify',timestamp='2026-07-02T03:00:00Z')
    foreign.update(userId=person,anonymousId=prefix+'foreigncookie',sourceService=prefix,schemaVersion=2,properties={'plan':'foreign'})
    send(base,other_token,[foreign])
    def foreign_visible():
        try: return api(profile_path,credential=other_token)['traits'].get('plan',{}).get('value')=='foreign'
        except AssertionError: return False
    eventually(foreign_visible)
    assert api(profile_path)['traits']['plan']['value']=='pro'
    for bots in ['false','true']:
        counts=api('/users/activity-counts',includeBots=bots,**dates)
        total=sum(p['value'] for p in api('/metrics/users',timeGrain='none',includeBots=bots,**dates)['points'])
        assert counts['identified']+counts['anonymous']==total
    assert api(search=prefix+'Bot')['edges'][0]['node']['firstActivityAt'] is None
    assert api(search=prefix+'Bot',includeBots='true')['edges'][0]['node']['firstActivityAt'] is not None
    alias=event(prefix+'alias',prefix,name='alias',timestamp='2026-07-04T01:00:00Z')
    alias.update(userId=person,anonymousId=prefix+'ALIAS_SECRET',sourceService=prefix,properties={'previousId':prefix+'ALIAS_SECRET','newId':person})
    send(base,write_key,[alias])
    eventually(lambda: len(api(profile_path+'/events',filter=[filt('event_name','eq','alias')])['edges'])==1)
    alias_page=api(profile_path+'/events',filter=[filt('event_name','eq','alias')])
    assert alias_page['edges'][0]['node']['properties']=={} and prefix+'ALIAS_SECRET' not in json.dumps(alias_page)
    previous_total=api(profile_path)['retainedEventCount']
    saved=api(profile_path+'/events',first=1)
    arrival=event(prefix+'arrival',prefix,name='feature_used',timestamp='2026-07-05T00:00:00Z')
    arrival.update(userId=person,anonymousId=prefix+'cookie',properties={'feature':prefix},sourceService=prefix)
    send(base,write_key,[arrival])
    eventually(lambda: api(profile_path+'/events',first=1)['edges'][0]['node']['eventId']==prefix+'arrival')
    continuation=api(profile_path+'/events',after=saved['pageInfo']['endCursor'])
    assert prefix+'arrival' not in {e['node']['eventId'] for e in continuation['edges']}
    assert len(continuation['edges'])==previous_total-1
    if erase_user is not None:
        erase_user(person)
        api(profile_path,expected=404)
        api(profile_path+'/events',expected=404)
        assert not api(search=person)['edges']
        # Replay the erased source IDs; the administrative tombstones fence them.
        send(base,write_key,rows+observed[:1])
        api(profile_path,expected=404)
    print('Users HTTP acceptance: directory, profile, safe resolved history, split counts, bidirectional pagination and erasure passed.',flush=True)

    return prefix


def verify_owned_users(base, write_key, token, other_token, *, env, **kwargs):
    prefix=verify_users(base,write_key,token,other_token,**kwargs)
    from isolated_clickhouse import _OWNED_STACKS
    from test_support import binary
    assert env.get('KANSOKU_OWNED_CLICKHOUSE_ROOT') in _OWNED_STACKS
    assert env.get('KANSOKU_OWNED_POSTGRES_ROOT')
    person=prefix+'retained'
    path='/users/'+person
    def read(path=path,expected=200):
        req=urllib.request.Request(base+path,headers={'Authorization':'Bearer '+token})
        try: response=urllib.request.urlopen(req,timeout=40)
        except urllib.error.HTTPError as error: response=error
        assert response.code==expected,(response.code,path)
        return json.load(response)
    def ch(sql):
        return subprocess.check_output(['clickhouse-client','--host','127.0.0.1','--port',env['CLICKHOUSE_TCP_PORT'],'--param_user='+person,'--query',sql],text=True).strip()
    ch('SYSTEM STOP TTL MERGES analytics.identity_signal_users')
    fresh=datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z')
    rows=[]
    for eid,name,stamp,props,ids in [
        ('expired','identify','2024-01-01T00:00:00Z',{}, {'fingerprint':prefix+'expired'}),
        ('trait','identify','2026-07-01T00:00:00Z',{'plan':'old'},{'device':prefix+'olddevice'}),
        ('old','feature_used','2024-01-02T00:00:00Z',{'feature':prefix},{}),
        ('fresh','feature_used',fresh,{'feature':prefix},{})]:
        row=event(prefix+'retain'+eid,prefix+'retain'+eid,name=name,timestamp=stamp)
        row.update(userId=person,anonymousId=prefix+'oldcookie' if name=='identify' else '',schemaVersion=2 if name=='identify' else 1,properties=props,identifiers=ids)
        rows.append(row)
    for row in rows: send(base,write_key,[row])
    def visible():
        try: return read()['retainedEventCount']==4
        except AssertionError: return False
    eventually(visible)
    before=read()
    assert before['traits']['plan']['value']=='old' and before['identityEvidence']['device']==1
    assert before['firstActivityAt'].startswith('2024-01-02')
    assert int(ch("SELECT count() FROM analytics.identity_signal_users WHERE user_id={user:String} AND signal_kind='fingerprint'"))>0
    assert before['identityEvidence']['fingerprint']==0, before
    retention_env=dict(env,KANSOKU_EVENTS_RETENTION_DAYS='90')
    result=subprocess.run([os.environ.get('KANSOKU_COHORT_ADMIN') or binary('kansoku-server:exe:kansoku-admin'),'apply-retention','--out',str(Path(env['KANSOKU_OWNED_POSTGRES_ROOT']).parent/'users-retention.json'),'--confirm'],env=retention_env,capture_output=True,text=True,timeout=120)
    assert result.returncode==0,result.stderr
    assert json.loads(result.stdout)['stage']=='complete'
    after=read()
    assert after['retainedEventCount']==1 and after['traits']=={} and not any(after['identityEvidence'].values()),after
    assert after['firstActivityAt']==after['lastActivityAt']==fresh
    read('/users/'+prefix+'C',expected=404)
    assert len(read(path+'/events')['edges'])==1
    print('Users lifecycle: physical expired fingerprint excluded before cleanup; applied retention refreshes extrema/counts/traits/evidence and removes empty users.',flush=True)
    # A second owned server forces actual query-budget exhaustion on all routes.
    from isolated_clickhouse import free_port
    limited=dict(env,KANSOKU_SERVER_PORT=str(free_port()),KANSOKU_METRICS_MAX_MEMORY_BYTES='1')
    limited_base='http://127.0.0.1:'+limited['KANSOKU_SERVER_PORT']
    with (Path(env['KANSOKU_OWNED_POSTGRES_ROOT']).parent/'users-resource-limit.log').open('w') as log:
        process=subprocess.Popen([os.environ.get('KANSOKU_COHORT_SERVER') or binary('kansoku-server:exe:kansoku-server')],env=limited,stdout=log,stderr=log)
        try:
            def live():
                assert process.poll() is None, 'limited server exited'
                try: return urllib.request.urlopen(limited_base+'/health/live',timeout=2).status==200
                except (OSError,urllib.error.URLError): return False
            eventually(live)
            for resource in ['/users',path,path+'/events','/users/activity-counts?from=2026-11-01&to=2026-11-20']:
                req=urllib.request.Request(limited_base+resource,headers={'Authorization':'Bearer '+token})
                try: response=urllib.request.urlopen(req,timeout=40)
                except urllib.error.HTTPError as error: response=error
                body=json.load(response)
                assert response.code==503 and response.headers['Content-Type'].startswith('application/problem+json'),(resource,response.code,body)
                assert body['code']=='clickhouse_unavailable' and not ({'edges','points','identified','traits'} & set(body)),body
        finally:
            process.terminate()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
    print('Users resource limits: all four routes return complete 503 problems under actual native memory exhaustion.',flush=True)



if __name__=='__main__': main(verify_owned_users, pass_environment=True, erase_delete_events=True)
