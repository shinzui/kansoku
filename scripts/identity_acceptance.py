#!/usr/bin/env python3
"""Owned conservative identity proof, including native index/view rebuilds."""
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import subprocess

from isolated_clickhouse import isolated_clickhouse, apply_migrations
from test_support import binary


def source(account='identity-a', start='2026-07-01', end='2026-07-02'):
    # Fixture constants only; HTTP uses the compiled native-parameter helper.
    return ("analytics.events_resolved_internal(scope_all_accounts=0,scope_account='" + account
            + "',scope_from=toDateTime64('" + start + "',3,'UTC'),scope_to=toDateTime64('" + end + "',3,'UTC'))")


def verify_identity(env):
    client = ['clickhouse-client', '--host', '127.0.0.1', '--port', env['CLICKHOUSE_TCP_PORT']]

    generated = json.loads(subprocess.check_output([binary('kansoku-core:test:kansoku-core-test')],
        env=dict(env,KANSOKU_IDENTITY_BENCH_SQL='1',KANSOKU_IDENTITY_BENCH_FROM='2026-07-01',KANSOKU_IDENTITY_BENCH_TO='2026-07-02'),text=True))
    cache_setup = ';\n'.join(generated['cacheSetup'])+';\n'

    def ch(sql,cache_account='identity-a'):
        if 'analytics.events_resolved_http(' in sql:
            sql=cache_setup+sql
        return subprocess.check_output(client + ['--param_cache_account='+cache_account,'--param_cache_from=2026-07-01','--param_cache_to=2026-07-02','--multiquery'], input=sql, env=env, text=True, timeout=90).strip()

    rows = []
    expected = {}

    def event(key, *, cookie='', user='', session='', name='activity', minute=0, account='identity-a',
              service='web-a', ids=None, day='2026-07-01', occurred=None):
        stamp = occurred or f'{day} 00:{minute:02}:00.000'
        rows.append(dict(event_id=key, event_name=name, account_id=account, source='web', source_service=service,
                         occurred_at=stamp, received_at='2026-10-14 12:00:00.000', anonymous_id=cookie,
                         user_id=user, session_id=session, identifiers=json.dumps(ids or {}), properties='{}', context='{}'))
        return key

    def expect(key, subject, **values):
        expected[key] = subject
        event(key, **values)

    # Evidence arrives before/after activity in reverse order, independently of occurrence.
    event('login-b', cookie='shared', user='B', session='s2', name='identify', minute=40)
    event('login-a', cookie='shared', user='A', session='s1', name='alias', minute=20)
    expect('pre-a', 'user:A', cookie='shared', session='s1', minute=1)
    expect('pre-b', 'user:B', cookie='shared', session='s2', minute=30)
    expect('between', 'anonymous:shared', cookie='shared', minute=25)
    event('session-conflict-a', cookie='shared', user='A', session='bad', name='identify', minute=51)
    event('session-conflict-b', cookie='shared', user='B', session='bad', name='identify', minute=52)
    expect('session-conflict-pre', 'anonymous:shared', cookie='shared', session='bad', minute=50)
    expect('other-service', 'anonymous:shared', cookie='shared', session='s1', service='web-b')
    # Byte-length prefixes distinguish separators and multi-byte UTF-8 components.
    event('encoded-login-a',cookie='encoded:shared',user='encoded-A',service='wéb:a',session='b',name='identify')
    event('encoded-login-b',cookie='encoded:shared',user='encoded-B',service='wéb',session='a:b',name='identify')
    expect('encoded-pre-a','user:encoded-A',cookie='encoded:shared',service='wéb:a',session='b')
    expect('encoded-pre-b','user:encoded-B',cookie='encoded:shared',service='wéb',session='a:b')
    event('outside-binding', cookie='unique', user='F', name='identify_once', day='2026-07-03')
    expect('outside-window', 'user:F', cookie='unique')
    event('other-account-binding', cookie='shared', user='Z', name='identify', account='identity-b')
    expect('explicit', 'user:explicit', cookie='shared', user='explicit', session='bad')
    expect('no-identity', '')
    expect('namespace-anon', 'anonymous:same', cookie='same', account='namespace')
    expect('namespace-user', 'user:same', user='same', account='namespace')
    expect('prefix-anon', 'anonymous:user:same', cookie='user:same')
    event('email-high', user='E', ids={'email_hmac': 'v1:email'})
    event('device-low', user='D', ids={'device': 'device'})
    expect('ranked', 'user:E', cookie='rank', ids={'device': 'device', 'email_hmac': 'v1:email'})
    event('email-conflict-a', user='A', ids={'email_hmac': 'v1:shared'})
    event('email-conflict-b', user='B', ids={'email_hmac': 'v1:shared'})
    expect('unique-before-ranking', 'user:D', cookie='rank', ids={'device': 'device', 'email_hmac': 'v1:shared'})
    event('email-tie', user='B', ids={'email_sha256': 'legacy'})
    expect('confidence-tie', 'anonymous:tie', cookie='tie', ids={'email_sha256': 'legacy', 'email_hmac': 'v1:email'})
    expect('explicit-tie', 'user:explicit', user='explicit', cookie='tie', ids={'email_hmac': 'v1:shared'})
    old = (datetime.now(timezone.utc) - timedelta(days=181)).strftime('%Y-%m-%d %H:%M:%S.000')
    ch('SYSTEM STOP TTL MERGES analytics.identity_signal_users; SYSTEM STOP TTL MERGES analytics.identity_signals')
    event('expired-binding', user='old-user', ids={'fingerprint': 'expired'}, occurred=old)
    expect('expired', 'anonymous:expired-cookie', cookie='expired-cookie', ids={'fingerprint': 'expired'})
    event('fresh-binding', user='fresh-user', ids={'fingerprint': 'fresh'})
    expect('fresh', 'user:fresh-user', cookie='fresh-cookie', ids={'fingerprint': 'fresh'})
    event('mapped-session-binding', user='mapped-user', session='mapped', ids={'cookie': 'mapped-cookie'})
    expect('mapped-session', 'user:mapped-user', session='mapped', ids={'cookie': 'mapped-cookie'})

    ch('SYSTEM STOP MERGES analytics.events_raw')
    ch('INSERT INTO analytics.events_raw FORMAT JSONEachRow\n' + '\n'.join(json.dumps(row) for row in rows))
    # Two physical parts, one logical row, and replay-safe index states.
    ch('INSERT INTO analytics.events_raw FORMAT JSONEachRow\n' + json.dumps(rows[0]))

    def verify():
        observed = {}
        for account in ['identity-a', 'identity-b', 'namespace', '']:
            data = ch('SELECT event_id,canonical_user FROM ' + source(account) + ' FORMAT JSONEachRow')
            result = [json.loads(line) for line in data.splitlines() if line]
            assert len({row['event_id'] for row in result}) == len(result), 'identity join fanned out'
            observed.update({row['event_id']: row['canonical_user'] for row in result})
            cached = ch('SELECT event_id,canonical_user FROM ' + source(account).replace('events_resolved_internal','events_resolved_http') + ' ORDER BY event_id FORMAT JSONEachRow',cache_account=account)
            assert [json.loads(line) for line in cached.splitlines() if line] == sorted(result,key=lambda row:row['event_id']), 'cached/direct subject semantics diverged' 
            if account == '':
                assert not result, 'empty account bypassed account scoping'
        for key, subject in expected.items():
            assert observed[key] == subject, (key, observed[key], subject)
        assert ch("SELECT canonical_user FROM " + source('identity-b') + " WHERE event_id='other-account-binding'") == 'user:Z'
        assert ch("SELECT observed_at=toDateTime64('2026-07-01 00:20:00',3,'UTC') AND received_at>observed_at AND source_service='web-a' AND session_id='s1' FROM analytics.identity_signals FINAL WHERE event_id='login-a'") == '1'
        assert int(ch("SELECT count() FROM analytics.identity_conflicts WHERE signal_value IN ('shared','v1:shared')")) == 2
        for table in ['dau', 'wau']:
            assert ch(f"SELECT uniqCombinedMerge(users) FROM analytics.{table} WHERE account_id='namespace'") == '2'
        columns = ch('DESCRIBE analytics.events_resolved').splitlines()
        assert [line.split('\t')[0] for line in columns] == ['event_id','event_name','occurred_at','url','account_id','canonical_user','properties_json']
        assert ch("SELECT subject_kind || ':' || subject_id FROM " + source() + " WHERE event_id='pre-a'") == 'user:A'

    assert int(ch("SELECT count() FROM analytics.identity_signal_users WHERE signal_kind='fingerprint' AND signal_value='expired'")) > 0, 'expiry fixture must exist physically before query-time filtering'
    verify()
    ch('SYSTEM START MERGES analytics.events_raw; OPTIMIZE TABLE analytics.events_raw FINAL')
    verify()
    ch(Path('db/clickhouse/migrations/0018_conservative_identity_resolution.sql').read_text())
    verify()
    print(f'Conservative identity: {len(expected)} expected subjects, no fanout, account isolation, namespaced sketches and repeat rebuild passed.', flush=True)


def main():
    with isolated_clickhouse() as env:
        apply_migrations(env)
        verify_identity(env)


if __name__ == '__main__':
    main()
