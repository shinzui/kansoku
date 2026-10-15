#!/usr/bin/env python3
"""Owned identity cost gate: actual compiler SQL, five-run medians, 10M facts."""
import argparse
import json
import os
from pathlib import Path
import platform
import select
import statistics
import subprocess
import tempfile
import time
import uuid

from isolated_clickhouse import isolated_clickhouse, apply_migrations
from test_support import binary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--rows', type=int, default=10_000_000)
    args = parser.parse_args()
    assert args.rows >= 1000
    os.umask(0o077)
    parent = Path('.dev/acceptance')
    parent.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='identity-bench-', dir=parent)).resolve()
    print('Private identity measurement: ' + str(root), flush=True)
    subprocess.run(['cabal', 'build', 'kansoku-core:test:kansoku-core-test'], check=True)
    test = binary('kansoku-core:test:kansoku-core-test')
    clean = {k: v for k, v in os.environ.items() if not k.startswith(('PG', 'CLICKHOUSE', 'KANSOKU_', 'OTEL_'))}
    report = dict(rows=args.rows, required_size=args.rows >= 10_000_000,
                  platform=platform.platform(), architecture=platform.machine(), max_threads=4,
                  settings=dict(anonymous_fraction=.70, identified_cookie_fraction=.40,
                                accounts=2, runs=5, shared_cookie_conflicts=True), results=[])
    if platform.system() == 'Darwin':
        report['cpu'] = subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip()
        report['memory_bytes'] = int(subprocess.check_output(['sysctl', '-n', 'hw.memsize']))
    session = None
    saved = dict(os.environ)
    os.environ.clear()
    os.environ.update(clean)
    try:
        with isolated_clickhouse(directory=root / 'clickhouse', query_logging=True) as env:
            apply_migrations(env)
            client = ['clickhouse-client', '--host', '127.0.0.1', '--port', env['CLICKHOUSE_TCP_PORT']]

            def ch(sql, extra=(), timeout=180):
                return subprocess.check_output(client + list(extra) + ['--multiquery'], input=sql,
                                               env=env, text=True, timeout=timeout).strip()

            report['engine'] = ch('SELECT version()')
            ch('DESCRIBE system.query_log')  # Required native instrumentation, never a guessed fallback.
            recent = min(3_000_000, max(1000, args.rows * 3 // 10))
            cookies = min(100_000, max(100, args.rows // 100))

            def seed(offset, count, old):
                # Stable recent population; append older account history in phase two.
                stamp = (f"toDateTime64('2026-08-31',3,'UTC') - toIntervalDay(intHash64(cookie+intDiv(number,{cookies*40}))%335)"
                         if old else f"toDateTime64('2026-09-30',3,'UTC') - toIntervalDay(intHash64(cookie+intDiv(number,{cookies*40}))%30)")
                sql = f'''INSERT INTO analytics.events_raw
                    (event_id,event_name,account_id,source,source_service,occurred_at,received_at,
                     anonymous_id,user_id,session_id,properties,context)
                    WITH intDiv(number,2)%{cookies} AS cookie,
                         (intDiv(number,{cookies*2})+cookie)%10>=7 AS identified,
                         cookie%10<4 AS bound,
                         concat('u',toString(cookie),if(cookie%100=0 AND intDiv(number,{cookies*40})%2=1,'-shared','')) AS subject
                    SELECT concat('bench-',toString(number)),
                           if(identified AND bound,'identify',multiIf(intHash64(number+31)%3=0,'signup_started',intHash64(number+31)%3=1,'signup_completed','page_view')),
                           if(number%2=0,'bench-a','bench-b'),'web','bench-web',
                           {stamp} + toIntervalSecond((intDiv(number,{cookies*2})%20)*60),
                           toDateTime64('2026-10-01',3,'UTC'),concat('c',toString(cookie)),
                           if(identified,subject,''),concat('s',toString(cookie),'-',toString(intDiv(number,{cookies*40})),'-{"old" if old else "recent"}'), '{{}}','{{}}'
                    FROM numbers({offset},{count})'''
                began = time.monotonic()
                ch(sql, timeout=300)
                # Consolidate raw parts and the replay-safe lookup indexes before timing.
                for table in ['events_raw', 'identity_signal_users', 'identity_session_users', 'identity_context_signals']:
                    ch('OPTIMIZE TABLE analytics.' + table + ' FINAL', timeout=300)
                print(f'Seeded {count} {"older" if old else "recent"} events in {time.monotonic()-began:.2f}s.', flush=True)

            def sql_for(start):
                emitted = subprocess.check_output([test], env=dict(env, KANSOKU_IDENTITY_BENCH_SQL='1',
                                  KANSOKU_IDENTITY_BENCH_FROM=start, KANSOKU_IDENTITY_BENCH_TO='2026-10-01'), text=True, timeout=20)
                return json.loads(emitted)

            baseline_view = """CREATE OR REPLACE VIEW analytics.events_unresolved_http AS
                SELECT *,if(user_id!='',concat('user:',user_id),if(anonymous_id!='',concat('anonymous:',anonymous_id),'')) AS canonical_user
                FROM analytics.events_canonical
                WHERE ({scope_all_accounts:UInt8}=1 OR account_id={scope_account:String})
                  AND occurred_at>={scope_from:DateTime64(3,'UTC')} AND occurred_at<{scope_to:DateTime64(3,'UTC')}"""
            ch(baseline_view)
            session_log = (root/'query-session.log').open('w')
            session = subprocess.Popen([test],env=dict(env,KANSOKU_IDENTITY_BENCH_SESSION='1'),
                                       stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=session_log,text=True,bufsize=1)

            def measure(name, start, baseline, *, cold=False, evidence_only=False):
                tag = 'identity_' + uuid.uuid4().hex
                request = dict(fromDay=start,toDay='2026-10-01',queryName=name,baseline=baseline,cold=cold,evidenceOnly=evidence_only,tag=tag)
                session.stdin.write(json.dumps(request)+'\n')
                session.stdin.flush()
                ready,_,_ = select.select([session.stdout],[],[],120)
                assert ready, 'production query session exceeded its watchdog'
                line = session.stdout.readline()
                assert line, 'production query session exited; inspect private log'
                measured = json.loads(line)
                if 'error' in measured:
                    (root/'query-error.json').write_text(json.dumps(measured,indent=2)+'\n')
                    raise RuntimeError(measured['error'][:700])
                assert measured['result_rows'] > 0
                ch('SYSTEM FLUSH LOGS')
                stats = json.loads(ch("SELECT sum(query_duration_ms) AS total_ms,sum(read_rows) AS total_rows,sum(read_bytes) AS total_bytes,max(memory_usage) AS peak_bytes,count() AS native_statements,min(is_initial_query) AS all_initial,groupArray(tuple(query_kind,left(query,90),query_duration_ms,read_rows,memory_usage)) AS statements FROM system.query_log WHERE type='QueryFinish' AND client_name='ClickHaskell' AND (query_kind!='Set' OR startsWith(query,'SET max_execution_time=')) AND log_comment='" + tag + "' FORMAT JSONEachRow"))
                for output,source in [('query_duration_ms','total_ms'),('read_rows','total_rows'),('read_bytes','total_bytes'),('memory_usage','peak_bytes')]:
                    stats[output]=stats.pop(source)
                assert stats['native_statements'] > 0, 'missing native statement instrumentation'
                assert stats['all_initial'] == 1, 'driver misclassified initial native requests'
                stats.update(measured)
                return stats

            def median(name, start, baseline):
                cold = measure(name,start,baseline)
                runs = [measure(name,start,baseline) for _ in range(5)]
                assert len(runs) == 5 and all(run['read_rows'] > 0 for run in runs)
                return dict(median_ms=statistics.median(run['query_duration_ms'] for run in runs),
                            median_wall_seconds=statistics.median(run['wall_seconds'] for run in runs),
                            median_read_rows=statistics.median(run['read_rows'] for run in runs),
                            median_read_bytes=statistics.median(run['read_bytes'] for run in runs),
                            maximum_memory_usage=max(run['memory_usage'] for run in runs), cold=cold, runs=runs)

            def phase(label):
                for window, start in [('day','2026-09-30'),('month','2026-09-01')]:
                    evidence_runs = [measure('conversion',start,False,cold=True,evidence_only=True) for _ in range(5)]
                    report.setdefault('evidence',[]).append(dict(phase=label,window=window,runs=evidence_runs,
                        median_ms=statistics.median(r['query_duration_ms'] for r in evidence_runs),
                        median_read_rows=statistics.median(r['read_rows'] for r in evidence_runs),
                        median_read_bytes=statistics.median(r['read_bytes'] for r in evidence_runs),
                        maximum_memory_usage=max(r['memory_usage'] for r in evidence_runs),
                        physical_index_bytes=int(ch("SELECT coalesce(sum(bytes_on_disk),0) FROM system.parts WHERE database='analytics' AND table IN ('identity_signal_users','identity_session_users','identity_context_signals') AND active"))))
                    generated = sql_for(start)
                    queries = generated['queries']
                    for name in ['funnel','retention','conversion']:
                        sql = queries[name]
                        assert queries['source'] in sql, 'benchmark did not exercise the actual bounded resolver'
                        unresolved = median(name,start,True)
                        resolved = median(name,start,False)
                        ratio = resolved['median_ms'] / max(1, unresolved['median_ms'])
                        row = dict(phase=label, window=window, metric=name, resolved=resolved,
                                   unresolved=unresolved, latency_ratio=ratio, target_pass=ratio < 2)
                        report['results'].append(row)
                        (root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
                        print(f'{label} {window} {name}: {unresolved["median_ms"]}ms raw / {resolved["median_ms"]}ms resolved ({ratio:.2f}x).', flush=True)
                (root/'report.json').write_text(json.dumps(report,indent=2)+'\n')

            seed(0, recent, False)
            phase('recent-only')
            seed(recent, args.rows-recent, True)
            assert int(ch('SELECT count() FROM analytics.events_canonical')) == args.rows
            report['actual_anonymous_fraction'] = float(ch("SELECT countIf(user_id='')/count() FROM analytics.events_canonical"))
            report['actual_identified_cookie_fraction'] = float(ch('SELECT countDistinct(tuple(account_id,signal_value)) FROM analytics.identity_signal_users')) / (2*cookies)
            phase('grown-history')
            report['passed'] = all(row['target_pass'] for row in report['results'])
            (root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
            session.stdin.close()
            session.wait(timeout=10)
            session_log.close()
            assert session.returncode == 0
            assert report['passed'], 'identity latency target missed; preserve report and optimize before acceptance'
            print('Owned identity benchmark passed; required size: ' + str(report['required_size']), flush=True)
    finally:
        if session is not None and session.poll() is None:
            session.terminate()
            session.wait(timeout=10)
        os.environ.clear()
        os.environ.update(saved)


if __name__ == '__main__':
    main()
