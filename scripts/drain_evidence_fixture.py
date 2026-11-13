"""Receipt serialization for explicit owned-fixture drain producers.

Callers must establish exclusion and drain before calling this module. It does
not infer either guarantee from an empty process list or manufacture platform proof.
"""
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path


def write_evidence(path, env, owner, procedure, *, servers=None, submitters=None, owned_fixture=None):
    if owned_fixture is None:
        root = Path(env['KANSOKU_OWNED_CLICKHOUSE_ROOT']).resolve()
        assert root.is_dir() and (root / 'pid').is_file(), 'Evidence requires an owned native fixture'
    else:
        # The bridge's native_ports/controller has already checked process or
        # Apple container identities. It supplies the exact fixture descriptor.
        assert owned_fixture.get('engine') in ('apple', 'nix')
        assert len(owned_fixture['replicas']) == 2
        root = Path(owned_fixture['root']).resolve()
        assert root.is_dir()
    user = env.get('KANSOKU_CLICKHOUSE_USER', 'default')
    servers = servers or [env['KANSOKU_CH_MIGRATION_SERVER_ID']]
    submitters = submitters or [user]
    now = datetime.now(timezone.utc)
    source = Path(str(path) + '.procedure')
    source.write_text(procedure)
    value = dict(schemaVersion=1, target=env['KANSOKU_CH_MIGRATION_TARGET'], servers=servers,
                 ledger=env['KANSOKU_CH_MIGRATION_LEDGER_ID'], databases=['analytics', 'kansoku_migration_ledger'],
                 submitters=submitters, availablePrincipals=[user], owner=owner,
                 exclusionStartedAt=now.isoformat(), drainedAt=now.isoformat(), expiresAt=(now + timedelta(minutes=30)).isoformat(),
                 procedureReference=str(source), procedureSha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                 submittersBlocked=True, schedulesPaused=True, backgroundChangesSettled=True, operatorAttested=True)
    Path(path).write_text(json.dumps(value))
    return dict(env, KANSOKU_CH_DRAIN_SERVERS=json.dumps(servers), KANSOKU_CH_DRAIN_SUBMITTERS=json.dumps(submitters), KANSOKU_CH_DRAIN_AVAILABLE_PRINCIPALS=json.dumps([user]))


def run_maintenance(command, *, env, producer, **kwargs):
    """Execute a direct owned fixture's explicit prepare/drain/resume ceremony.

    producer names the fixture's authority over direct clients. Its caller must
    have joined those clients and paused external schedules before invoking it.
    Cooperating runtime workers are excluded by the persisted fence and barrier.
    """
    import subprocess
    import time
    import uuid
    assert producer and command[1] in ('erase-user', 'apply-retention', 'resume-job')
    assert env.get('KANSOKU_CLICKHOUSE_USER', 'default') == 'default', 'This producer requires the fixture operator'
    settings = dict(env)
    timeout = kwargs.get('timeout', 120)
    def call(args):
        result = subprocess.run(args, env=settings, capture_output=True, text=True, timeout=timeout)
        result.check_returncode()
        return result.stdout.strip()
    marker = settings['KANSOKU_OWNED_POSTGRES_ROOT']
    assert call(['psql', '-XAt', '-c', 'SHOW data_directory']) == str(Path(marker).resolve())
    if command[1] == 'resume-job':
        ident = command[command.index('--id') + 1]
    else:
        prepared = json.loads(call([('--prepare' if arg == '--confirm' else arg) for arg in command]))
        ident = prepared['job_id']
    status = json.loads(call([command[0], 'job-status', '--id', ident]))
    if status['stage'] == 'complete':
        return subprocess.run(command, env=settings, **kwargs)
    call(['psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', 'SELECT pg_advisory_lock(726401,1)'])
    client = ['clickhouse-client', '--host', '127.0.0.1', '--port', settings['CLICKHOUSE_TCP_PORT'], '--query']
    root = Path(settings['KANSOKU_OWNED_CLICKHOUSE_ROOT']).resolve()
    assert call(client + ["SELECT value FROM system.server_settings WHERE name='path'"]).rstrip('/') == str(root / 'data')
    deadline = time.monotonic() + 60
    while call(client + ["SELECT count() FROM system.processes WHERE lower(query_kind)='insert' AND position(query,'events_raw')>0"]) != '0':
        assert time.monotonic() < deadline, 'owned prior INSERT failed to drain'
        time.sleep(.1)
    evidence = root / ('admin-drain-' + uuid.uuid4().hex + '.private')
    settings = write_evidence(evidence, settings, dict(kind='data-job', id=ident, attempt=status['next_attempt']), producer + '; persisted fence and exclusive PostgreSQL traffic barrier exclude cooperating workers; fixture operator drained prior INSERTs; no schedules exist')
    args = [command[0], 'resume-job', '--id', ident, '--confirm', '--drain-evidence', str(evidence)]
    if '--out' in command:
        args += ['--out', command[command.index('--out') + 1]]
    return subprocess.run(args, env=settings, **kwargs)


def _execute_owned(command, env, timeout):
    import subprocess
    process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    except BaseException:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        raise


def run_replicated_maintenance(command, *, env, fixture_path):
    """Bridge-owned producer: fence, drain both known endpoints, then resume."""
    import base64
    import subprocess
    import time
    import urllib.request
    import uuid
    fixture = json.loads(Path(fixture_path).read_text())
    assert fixture['engine'] in ('apple', 'nix')
    def call(args):
        result = _execute_owned(args, env, 120)
        result.check_returncode()
        return result.stdout.strip()
    if command[1] == 'resume-job':
        ident = command[command.index('--id') + 1]
    else:
        ident = json.loads(call(['--prepare' if arg == '--confirm' else arg for arg in command]))['job_id']
    status = json.loads(call([command[0], 'job-status', '--id', ident]))
    if status['stage'] == 'complete':
        return _execute_owned(command, env, 180)
    call(['psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', 'SELECT pg_advisory_lock(726401,1)'])
    ids = []
    for replica in fixture['replicas']:
        expected = json.loads(replica['body'].splitlines()[0])['id']
        deadline = time.monotonic() + 60
        while True:
            sql = "SELECT toString(serverUUID()) AS id,(SELECT count() FROM system.processes WHERE lower(query_kind)='insert' AND position(query,'events_raw')>0) AS active,(SELECT count() FROM system.mutations WHERE database='analytics' AND NOT is_done) AS mutations FORMAT JSONEachRow"
            request = urllib.request.Request(replica['endpoint'], data=sql.encode(), headers={'Authorization': 'Basic ' + base64.b64encode(b'default:test-password').decode()})
            with urllib.request.urlopen(request, timeout=10) as response:
                observed = json.loads(response.read())
            assert observed['id'] == expected, 'owned replica changed before drain'
            if observed['active'] == 0 and observed['mutations'] == 0:
                break
            assert time.monotonic() < deadline, 'owned predecessor work did not drain'
            time.sleep(.1)
        ids.append(expected)
    root = Path(fixture_path).parent
    evidence = root / ('replicated-job-drain-' + uuid.uuid4().hex + '.private')
    selected = write_evidence(evidence, env, dict(kind='data-job', id=ident, attempt=status['next_attempt']), 'Bridge owns all submitters and direct proxies; job fence and PostgreSQL exclusive barrier exclude cooperating workers; fixture operator drained INSERTs and mutations on both verified endpoints; no schedules exist.', servers=ids, owned_fixture=fixture)
    args = [command[0], 'resume-job', '--id', ident, '--confirm', '--drain-evidence', str(evidence)]
    if '--out' in command:
        args += ['--out', command[command.index('--out') + 1]]
    return _execute_owned(args, selected, 180)


if __name__ == '__main__':
    import os
    import sys
    import signal
    def interrupted(_signal, _frame):
        raise SystemExit('owned drain producer interrupted; fence retained')
    signal.signal(signal.SIGTERM, interrupted)
    assert sys.argv[1] == '--replicated-admin'
    result = run_replicated_maintenance(sys.argv[3:], env=dict(os.environ), fixture_path=sys.argv[2])
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    raise SystemExit(result.returncode)
