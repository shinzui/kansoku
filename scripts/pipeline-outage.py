#!/usr/bin/env python3
"""Owned native pipeline load, outage, restart and recovery measurement.

PostgreSQL is supplied by the Haskell ephemeral fixture. This process owns every
other process and retains only private evidence under .dev/acceptance.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

from isolated_clickhouse import apply_migrations, free_port, isolated_clickhouse


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', required=True)
    parser.add_argument('--seconds', type=int, default=600)
    args = parser.parse_args()
    assert args.seconds >= 1
    repo = Path(__file__).resolve().parent.parent
    os.chdir(repo)
    os.umask(0o077)
    parent = repo / '.dev/acceptance'
    parent.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='outage-', dir=parent))
    connection = os.environ['KANSOKU_OUTAGE_PG']
    clean = {key: value for key, value in os.environ.items() if not key.startswith(('PG', 'CLICKHOUSE', 'KANSOKU_', 'OTEL_'))}
    clean['PG_CONNECTION_STRING'] = connection
    processes = []
    account = 'outage_' + uuid.uuid4().hex
    stamp = datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')

    def spawn(command, env, name, stdout=None):
        with (root / (name + '.log')).open('w') as log:
            process = subprocess.Popen(command, env=env, stdout=stdout or log, stderr=log)
        processes.append(process)
        with (root / 'processes.jsonl').open('a') as inventory:
            inventory.write(json.dumps(dict(name=name, pid=process.pid)) + '\n')
        return process

    def stop(process, require_grace=False):
        began = time.monotonic()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=40)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
                if require_grace:
                    raise AssertionError('writer process did not stop within its total deadline')
        if require_grace:
            assert time.monotonic() - began < 38, 'graceful stop exceeded scheduling tolerance'
            assert process.returncode == 0, 'writer did not exit cleanly on SIGTERM'

    def pg(sql):
        return subprocess.check_output(['psql', connection, '-X', '-Atc', sql], env=clean, text=True, timeout=5).strip()

    def wait_for(check, seconds, label):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                if check():
                    return
            except (OSError, urllib.error.URLError, subprocess.CalledProcessError):
                pass
            time.sleep(.1)
        raise AssertionError(label + ' exceeded its deadline')

    def request(base, path, body=None, credential=None):
        headers = {'User-Agent':'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'}
        if credential:
            headers['Authorization'] = 'Bearer ' + credential
        if body is not None:
            headers['Content-Type'] = 'application/json'
        req = urllib.request.Request(base + path, headers=headers,
                                     data=None if body is None else json.dumps(body).encode())
        with urllib.request.urlopen(req, timeout=10) as response:
            data = response.read()
            return data.decode() if path == '/internal/metrics' else json.loads(data)

    def metric(base, name, labels=None):
        text = request(base, '/internal/metrics')
        for line in text.splitlines():
            if line.startswith('#') or not line:
                continue
            field, value = line.rsplit(' ', 1)
            if field.split('{', 1)[0] == name:
                observed = dict(re.findall(r'([a-zA-Z_][a-zA-Z0-9_]*)="([^"]*)"', field))
                if observed == (labels or {}):
                    return float(value)
        raise AssertionError('missing required pipeline metric: ' + name)

    def counters(base):
        return dict(accepted=metric(base, 'kansoku_ingest_events_total', {'outcome': 'accepted', 'transport': 'batch'}),
                    queued=metric(base, 'kansoku_ingest_newly_queued_total', {'transport': 'batch'}),
                    written=metric(base, 'kansoku_writer_events_written_total'))

    def event(prefix, number):
        kind = number % 20
        name = 'identify' if kind == 0 else 'identify_once' if kind == 1 else 'payment_completed' if kind == 19 else 'page_view'
        properties = ({'plan':'pro','company_size':10} if kind == 0 else {'signup_source':'capacity'} if kind == 1 else
                      {'amount':12.5,'plan':'pro'} if kind == 19 else {'url':'https://capacity.example.test/checkout?utm_source=owned&utm_medium=email','title':'Capacity proof'})
        value = dict(eventId=prefix + str(number), eventName=name, source='web',
                     schemaVersion=2 if kind == 0 else 1,
                     sourceService='owned-outage-proof', occurredAt=stamp, receivedAt=stamp, sentAt=stamp,
                     userId='synthetic-' + str(number // 20), anonymousId='cookie-' + str(number // 20),
                     sessionId=prefix + 'session-' + str(number // 20),
                     identifiers={'device':'device-' + str(number // 20)},
                     properties=properties, context={})
        # A mixed production-path workload exercises private queue v2, governed
        # traits, shared identity, nonempty sessions and HTTP UA/URL enrichment.
        value['properties']['padding'] = 'x' * max(0, 768 - len(json.dumps(value)) - 13)
        return value

    report = dict(requested_outage_seconds=args.seconds, events_per_second=200,
                  hardware=dict(platform=platform.platform(), architecture=platform.machine()),
                  settings=dict(writer_batch=5000, adapter_batch=1000, inbox=1, visibility_seconds=60,
                                probe_seconds=5, insert_deadline_seconds=30, source_prefetch=False,
                                ready_batch_capacity=1, retained_delivery_bound_per_process=11003),
                  packaged_server=args.server, workload='queue-v2 mixed identify-v2/identify_once/page_view/payment; nonempty source-scoped sessions; UA and URL enrichment; 768-byte target', samples=[])
    if platform.system() == 'Darwin':
        report['hardware'].update(cpu=subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
                                  memory_bytes=int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'])))
    try:
        saved = dict(os.environ)
        os.environ.clear()
        os.environ.update(clean)
        try:
            with isolated_clickhouse(directory=root / 'clickhouse') as env:
                apply_migrations(env)
                native_port = env['CLICKHOUSE_TCP_PORT']

                def ch(sql):
                    return subprocess.check_output(['clickhouse-client', '--host', '127.0.0.1', '--port', native_port,
                                                    '--multiquery'], input=sql, env=env, text=True, timeout=10).strip()

                def written(prefix):
                    return int(ch(f"SELECT count() FROM analytics.events_canonical WHERE account_id='{account}' AND startsWith(event_id,'{prefix}')"))

                sentinel = root / 'blocked'
                proxy = spawn(['python3', 'scripts/tcp-outage-proxy.py', native_port, str(sentinel)], env, 'proxy', subprocess.PIPE)
                proxy_port = proxy.stdout.readline().decode().strip()
                assert proxy_port.isdigit(), 'private proxy did not start'
                server_env = dict(env, CLICKHOUSE_TCP_PORT=proxy_port, KANSOKU_QUEUE_NAME='outage_events',
                                  KANSOKU_WRITER_MAX_BATCH='5000', KANSOKU_WRITER_ADAPTER_BATCH='1000',
                                  KANSOKU_WRITER_MAX_LATENCY_MS='100', KANSOKU_WRITER_VT_SEC='60',
                                  KANSOKU_QUEUE_POLL_INTERVAL_SEC='1', OTEL_SDK_DISABLED='true')
                issued = subprocess.check_output([args.server, 'issue-key', '--kind', 'write', '--account', account], env=server_env, text=True)
                token = re.search(r'ksk_w_[A-Za-z0-9_-]+', issued)[0]

                def start_server(number):
                    port = free_port()
                    process = spawn([args.server], dict(server_env, KANSOKU_SERVER_PORT=str(port)), 'server-' + str(number))
                    base = 'http://127.0.0.1:' + str(port)
                    wait_for(lambda: process.poll() is None and request(base, '/health/live'), 20, 'HTTP startup')
                    return process, base

                def post(base, values):
                    deadline = time.monotonic() + 30
                    while True:
                        try:
                            ack = request(base, '/v1/batch', values, token)
                            assert ack['accepted'] == len(values) and not ack['rejected'], 'unexpected ingest rejection'
                            return
                        except urllib.error.HTTPError as error:
                            if error.code not in (429, 503) or time.monotonic() >= deadline:
                                raise
                            time.sleep(min(5, max(1, int(error.headers.get('Retry-After', '1')))))
                        except (OSError, urllib.error.URLError):
                            if time.monotonic() >= deadline:
                                raise
                            time.sleep(.1)

                def block():
                    sentinel.touch()
                    time.sleep(.1)

                def reads():
                    return int(pg("SELECT coalesce(sum(read_ct),0) FROM pgmq.q_outage_events"))

                def valid_archive():
                    return int(pg("SELECT count(*) FROM pgmq.a_outage_events WHERE coalesce(message->'event'->>'eventId',message->>'eventId') LIKE 'outage_%'"))

                server, base = start_server(1)
                post(base, [event('warm_', 0)])
                wait_for(lambda: written('warm_') == 1, 10, 'writer warmup')

                # Native SQL/schema failure parks valid data; a successful ping
                # alone cannot reopen the source until the insert works again.
                ch('RENAME TABLE analytics.events_raw TO analytics.events_parked')
                post(base, [event('schema_', 0)])
                wait_for(lambda: metric(base, 'kansoku_writer_breaker_state') == 2, 10, 'schema-error park')
                parked_reads = reads()
                time.sleep(6)
                assert reads() == parked_reads, 'parked source kept reading'
                ch('RENAME TABLE analytics.events_parked TO analytics.events_raw')
                wait_for(lambda: written('schema_') == 1, 10, 'schema-error repair')
                pg("SELECT pgmq.send('outage_events', '\"malformed queued payload\"'::jsonb)")
                wait_for(lambda: int(pg('SELECT count(*) FROM pgmq.a_outage_events')) == 1, 10, 'malformed payload archive')
                wait_for(lambda: metric(base, 'kansoku_queue_archive_length') == 1, 10, 'archive gauge sample')

                # Independently measured conservative drain capacity includes
                # probe startup, rather than assuming a backlog drains in two flushes.
                block()
                for start in range(0, 5000, 500):
                    post(base, [event('calibration_', n) for n in range(start, start + 500)])
                wait_for(lambda: metric(base, 'kansoku_writer_breaker_state') == 1, 10, 'calibration pause')
                began = time.monotonic()
                sentinel.unlink()
                wait_for(lambda: written('calibration_') == 5000 and int(pg('SELECT count(*) FROM pgmq.q_outage_events')) == 0, 30, 'calibration drain')
                calibration_seconds = time.monotonic() - began
                capacity = 5000 / calibration_seconds
                assert capacity > 200, 'measured capacity cannot recover a 200 events/s stream'
                report.update(calibration_events=5000, calibration_seconds=calibration_seconds,
                              conservative_drain_events_per_second=capacity,
                              producer_event_bytes=len(json.dumps(event('outage_', 0))))

                block()
                baseline_counters = counters(base)
                retired_counters = None
                database_before = int(pg('SELECT pg_database_size(current_database())'))
                wal_before = pg('SELECT pg_current_wal_lsn()')
                began = time.monotonic()
                accepted = 0
                total = args.seconds * 200
                restarted = False
                last_sample = -10
                stable_reads = None
                while accepted < total:
                    elapsed = time.monotonic() - began
                    target = min(total, int(elapsed * 200) + 200)
                    while accepted < target:
                        size = min(500, target - accepted)
                        post(base, [event('outage_', n) for n in range(accepted, accepted + size)])
                        accepted += size
                    if not restarted and elapsed >= args.seconds / 2:
                        wait_for(lambda: metric(base, 'kansoku_writer_breaker_state') == 1, 10, 'open breaker before restart')
                        retired_counters = {key: value - baseline_counters[key] for key, value in counters(base).items()}
                        stop(server, require_grace=True)
                        server, base = start_server(2)
                        wait_for(lambda: metric(base, 'kansoku_writer_breaker_state') == 1, 10, 'open breaker after restart')
                        restarted = True
                        stable_reads = None
                    if elapsed - last_sample >= 10:
                        wait_for(lambda: metric(base, 'kansoku_writer_breaker_state') == 1, 10, 'outage source pause')
                        time.sleep(.2)  # allow the one already-issued native read to unwind
                        current = reads()
                        if stable_reads is not None:
                            assert current == stable_reads, 'source read count grew during the open breaker'
                        stable_reads = current
                        assert current <= 2 * (2 * 5000 + 1000 + 3), 'in-flight delivery bound exceeded across restart'
                        assert valid_archive() == 0, 'valid events archived during storage outage'
                        report['samples'].append(dict(seconds=round(elapsed, 3), accepted=accepted, reads=current,
                                                      queue=int(pg('SELECT count(*) FROM pgmq.q_outage_events'))))
                        (root / 'progress.json').write_text(json.dumps(report['samples'][-1]) + '\n')
                        last_sample = elapsed
                    time.sleep(min(.1, max(0, began + args.seconds - time.monotonic())))
                time.sleep(max(0, began + args.seconds - time.monotonic()))
                outage_seconds = time.monotonic() - began
                assert outage_seconds <= args.seconds * 1.05 + 40, 'producer could not sustain the scheduled load'
                assert written('outage_') == 0, 'outage proxy allowed an insert'
                assert int(pg(f"SELECT count(*) FROM kansoku.accepted_events WHERE account_id='{account}' AND event_id LIKE 'outage_%'")) == total
                database_after = int(pg('SELECT pg_database_size(current_database())'))
                wal_generated = int(float(pg(f"SELECT pg_wal_lsn_diff(pg_current_wal_lsn(),'{wal_before}')")))
                assert int(pg("SELECT count(*) FROM pgmq.q_outage_events WHERE (message->>'queueVersion')::int=2 AND message->'event'->>'sessionId' != ''")) == total
                oldest_age = float(pg("SELECT coalesce(extract(epoch FROM (now() - min(enqueued_at))),0) FROM pgmq.q_outage_events"))
                recovered = time.monotonic()
                sentinel.unlink()
                wait_for(lambda: written('outage_') > 0, 68, 'first recovered write')
                first_write = time.monotonic() - recovered
                bound = 68 + 1.5 * total / (capacity - 200)
                wait_for(lambda: written('outage_') == total and int(pg('SELECT count(*) FROM pgmq.q_outage_events')) == 0, bound, 'measured backlog drain')
                drain_seconds = time.monotonic() - recovered
                assert valid_archive() == 0
                assert metric(base, 'kansoku_writer_breaker_state') == 0
                final_counters = counters(base)
                assert retired_counters is not None
                measured = {key: final_counters[key] + retired_counters[key] for key in final_counters}
                assert measured['accepted'] >= total and measured['queued'] == total
                assert measured['written'] >= total
                report.update(accepted=total, newly_queued=measured['queued'], logically_written=written('outage_'),
                              wire_accepted=measured['accepted'], writer_successful_events=measured['written'],
                              accepted_events_per_second=measured['accepted'] / outage_seconds,
                              newly_queued_events_per_second=measured['queued'] / outage_seconds,
                              written_events_per_second_during_drain=measured['written'] / drain_seconds,
                              oldest_backlog_seconds=oldest_age,
                              actual_outage_seconds=outage_seconds, first_write_seconds=first_write,
                              drain_seconds=drain_seconds, drain_bound_seconds=bound,
                              postgres_database_growth_bytes=database_after - database_before,
                              postgres_wal_generated_bytes=wal_generated,
                              clickhouse_active_part_bytes=int(ch("SELECT coalesce(sum(bytes_on_disk),0) FROM system.parts WHERE database='analytics' AND active")),
                              valid_archived=valid_archive(), restarted_while_open=restarted,
                              long_outage_proof=args.seconds >= 600)
                stop(server, require_grace=True)
        finally:
            os.environ.clear()
            os.environ.update(saved)
        (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f"Owned outage proof passed: {report['accepted']} events, {report['actual_outage_seconds']:.1f}s outage, "
              f"{report['first_write_seconds']:.2f}s first write, {report['drain_seconds']:.2f}s drain, zero valid archives.", flush=True)
        print('Private measured evidence: ' + str(root / 'report.json'), flush=True)
    finally:
        for process in reversed(processes):
            stop(process)


if __name__ == '__main__':
    main()
