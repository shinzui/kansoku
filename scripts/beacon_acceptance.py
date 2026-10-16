"""Required real browser delivery against an owned server and fresh fixture account."""
import json
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import urllib.request
import uuid

from admin_acceptance import owned_process
from isolated_clickhouse import isolated_clickhouse, apply_migrations, free_port
from isolated_postgres import isolated_postgres
from test_support import binary


def verify_beacon_browser(server, admin, env, root, sdk, tokens=None):
    root = Path(root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    sdk = Path(sdk).resolve()
    assert (sdk / 'scripts/beacon-browser.ts').is_file(), 'required SDK browser beacon proof is missing'
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=sdk, text=True).strip()
    bundle = sdk / 'packages/kansoku-js/dist/index.js'
    (root / 'consumer.json').write_text(json.dumps(dict(source='mori://shinzui/kansoku-ts/packages/kansoku-js',
        commit=commit, bundle_sha256=hashlib.sha256(bundle.read_bytes()).hexdigest()), indent=2) + '\n')
    account = 'browser-' + uuid.uuid4().hex
    keys = []
    for kind in ('write', 'service'):
        result = subprocess.run([admin, 'issue-key', '--kind', kind, '--account', account],
                                env=env, capture_output=True, text=True, check=True, timeout=10)
        keys.append(result.stdout.strip().splitlines()[-2])
    if tokens is not None:
        tokens.extend(keys)
    port, origin_port, denied_port = free_port(), free_port(), free_port()
    base, origin, denied = [f'http://127.0.0.1:{value}' for value in (port, origin_port, denied_port)]
    settings = dict(env, KANSOKU_QUEUE_NAME='beacon_' + uuid.uuid4().hex,
                    KANSOKU_SERVER_PORT=str(port), KANSOKU_CORS_ORIGINS=origin,
                    KANSOKU_INGEST_QUARANTINE='true', KANSOKU_INGEST_MAX_BODY_BYTES='1048576',
                    KANSOKU_BEACON_BASE_URL=base, KANSOKU_BEACON_WRITE_KEY=keys[0],
                    KANSOKU_BEACON_SERVICE_TOKEN=keys[1], KANSOKU_BROWSER_ORIGIN=origin,
                    KANSOKU_BROWSER_DENIED_ORIGIN=denied)
    with (root / 'server.private').open('w') as log:
        with owned_process([server], settings, root, 'beacon-server', stdout=log, stderr=log) as process:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                assert process.poll() is None, 'owned beacon server exited during startup'
                try:
                    if urllib.request.urlopen(base + '/health/ready', timeout=2).status == 200:
                        break
                except OSError:
                    pass
                time.sleep(.1)
            else:
                raise RuntimeError('owned beacon server readiness timed out')
            with (root / 'browser.private').open('w') as browser_log:
                with owned_process(['bun', 'run', 'scripts/beacon-browser.ts'], settings, root,
                                   'chromium-consumer', cwd=sdk, stdout=browser_log, stderr=browser_log,
                                   start_new_session=True) as browser_process:
                    try:
                        browser_process.wait(timeout=150)
                    finally:
                        # The session belongs to this one fixture, including Chromium
                        # descendants if the consumer times out before its own cleanup.
                        try:
                            os.killpg(browser_process.pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                    assert browser_process.returncode == 0, 'required Chromium consumer failed; see private evidence'
            report = json.loads((root / 'browser.private').read_text().strip().splitlines()[-1])
            assert report['cases'] == 6 and report['skipped'] == 0 and report['result'] == 'passed'
    output = (root / 'server.private').read_text()
    assert all(key not in output for key in keys), 'beacon credential leaked into server logs/spans'
    # The wire envelope never enters either accepted queue payloads or quarantine.
    check = subprocess.run(['psql', '-XAtc', "SELECT count(*) FROM kansoku.ingest_rejections WHERE payload::text LIKE '%writeKey%'"],
                           env=env, capture_output=True, text=True, check=True, timeout=10)
    assert check.stdout.strip() == '0'
    (root / 'summary.log').write_text('Required Chromium beacon acceptance: 6 cases, 0 skipped, passed.\n')
    print('Required Chromium beacon acceptance: 6 cases, 0 skipped, passed.', flush=True)
    return 6


def main():
    os.umask(0o077)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(RuntimeError('beacon proof interrupted')))
    sdk = os.environ.get('KANSOKU_SDK_PROJECT')
    assert sdk, 'KANSOKU_SDK_PROJECT is required'
    root = Path(tempfile.mkdtemp(prefix='beacon-smoke-', dir='.dev/acceptance')).resolve()
    print('Private beacon evidence: ' + str(root), flush=True)
    with isolated_postgres(root / 'postgres') as pg_env:
        subprocess.run([binary('kansoku-server:exe:kansoku-migrate'), 'up'], env=pg_env, check=True, capture_output=True)
        saved = dict(os.environ)
        os.environ.clear(); os.environ.update(pg_env)
        try:
            with isolated_clickhouse(directory=root / 'clickhouse') as env:
                apply_migrations(env)
                verify_beacon_browser(binary('kansoku-server:exe:kansoku-server'), binary('kansoku-server:exe:kansoku-admin'), env, root / 'browser', sdk)
        finally:
            os.environ.clear(); os.environ.update(saved)


if __name__ == '__main__':
    main()
