"""Required cross-origin/shared-cookie/bot browser consumer in an owned environment."""
import hashlib
import json
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
from test_support import binary, execute


def verify_identity_browser(server, admin, env, root, sdk, tokens=None):
    root = Path(root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    sdk = Path(sdk).resolve()
    script = sdk / 'scripts/identity-browser.ts'
    assert script.is_file(), 'required cross-origin browser consumer is missing'
    bundle = sdk / 'packages/kansoku-js/dist/index.js'
    (root / 'consumer.json').write_text(json.dumps(dict(source='mori://shinzui/kansoku-ts/packages/kansoku-js',
        commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=sdk, text=True).strip(),
        bundle_sha256=hashlib.sha256(bundle.read_bytes()).hexdigest(),
        script_sha256=hashlib.sha256(script.read_bytes()).hexdigest()), indent=2) + '\n')
    keys = []
    account = 'cross-origin-' + uuid.uuid4().hex
    for kind in ('write', 'service'):
        output = subprocess.check_output([admin, 'issue-key', '--kind', kind, '--account', account], env=env, text=True)
        keys.append(output.strip().splitlines()[-2])
    if tokens is not None:
        tokens.extend(keys)
    port, browser_port = free_port(), free_port()
    base = f'http://127.0.0.1:{port}'
    origins = ','.join(f'http://{name}:{browser_port}' for name in ('www.example.test', 'app.example.test', 'app.another.test'))
    origins += ',http://127.0.0.1:4173,http://127.0.0.1:4174'
    settings = dict(env, KANSOKU_QUEUE_NAME='cross_' + uuid.uuid4().hex, KANSOKU_SERVER_PORT=str(port),
        KANSOKU_WRITER_MAX_LATENCY_MS='100', KANSOKU_QUEUE_POLL_INTERVAL_SEC='1', KANSOKU_CORS_ORIGINS=origins, KANSOKU_INGEST_MAX_BODY_BYTES='1048576', KANSOKU_INGEST_MAX_BATCH_LENGTH='50',
        KANSOKU_IDENTITY_BASE_URL=base, KANSOKU_IDENTITY_WRITE_KEY=keys[0],
        KANSOKU_IDENTITY_SERVICE_TOKEN=keys[1], KANSOKU_IDENTITY_BROWSER_PORT=str(browser_port))
    with (root / 'server.private').open('w') as log:
        with owned_process([server], settings, root, 'identity-browser-server', stdout=log, stderr=log) as process:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                assert process.poll() is None, 'owned browser server exited during startup'
                try:
                    if urllib.request.urlopen(base + '/health/ready', timeout=2).status == 200:
                        break
                except OSError:
                    pass
                time.sleep(.1)
            else:
                raise RuntimeError('owned browser server readiness timed out')
            live_env = dict(settings,KANSOKU_TEST_NO_DOM='1',KANSOKU_REQUIRE_LIVE='1',KANSOKU_LIVE_BASE_URL=base,KANSOKU_LIVE_WRITE_KEY=keys[0],KANSOKU_LIVE_SERVICE_TOKEN=keys[1],KANSOKU_LIVE_MAX_BATCH_EVENTS='50')
            live_result = execute(['bun','test','test/live'],env=live_env,cwd=sdk,timeout=180)
            evidence = live_result.stdout + live_result.stderr
            (root / 'live.private').write_text(evidence)
            live_result.check_returncode()
            import re
            assert re.search(r'\b9 pass\b',evidence) and re.search(r'\b0 fail\b',evidence) and not re.search(r'\b[1-9]\d* skip\b',evidence), 'required SDK live gate needs nine passing cases and zero skips'
            print('Required SDK live contract: 9 cases, 0 skipped, passed.',flush=True)
            example_env=dict(live_env,KANSOKU_SMOKE_BASE_URL=base,KANSOKU_SMOKE_WRITE_KEY=keys[0])
            examples=execute(['bun','node_modules/@playwright/test/cli.js','test','--config','test/smoke/playwright.config.ts','test/smoke/live-examples.pw.ts'],env=example_env,cwd=sdk,timeout=180)
            example_log=examples.stdout+examples.stderr
            (root / 'live-examples.private').write_text(example_log)
            examples.check_returncode()
            assert re.search(r'\b2 passed\b',example_log) and not re.search(r'\b[1-9]\d* skipped\b',example_log), 'required live examples need two cases and zero skips'
            print('Required vanilla/React real-server examples: 2 cases, 0 skipped, passed.',flush=True)
            result = execute(['bun', 'run', 'scripts/identity-browser.ts'], env=settings, cwd=sdk, timeout=240)
            (root / 'browser.private').write_text(result.stdout + result.stderr)
            result.check_returncode()
            report = json.loads(result.stdout.strip().splitlines()[-1])
            assert report['cases'] == 8 and report['skipped'] == 0 and report['result'] == 'passed'
    assert all(key not in (root / 'server.private').read_text() for key in keys)
    (root / 'summary.log').write_text('Required Chromium shared-identity/handoff/bot acceptance: 8 cases, 0 skipped, passed.\n')
    print('Required Chromium shared-identity/handoff/bot acceptance: 8 cases, 0 skipped, passed.', flush=True)
    return 8


def main():
    os.umask(0o077)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(RuntimeError('identity browser proof interrupted')))
    sdk = os.environ.get('KANSOKU_SDK_PROJECT')
    assert sdk, 'KANSOKU_SDK_PROJECT is required'
    root = Path(tempfile.mkdtemp(prefix='identity-browser-', dir='.dev/acceptance')).resolve()
    print('Private identity browser evidence: ' + str(root), flush=True)
    with isolated_postgres(root / 'postgres') as pg_env:
        subprocess.run([binary('kansoku-server:exe:kansoku-migrate'), 'up'], env=pg_env, check=True, capture_output=True)
        saved = dict(os.environ)
        os.environ.clear(); os.environ.update(pg_env)
        try:
            with isolated_clickhouse(directory=root / 'clickhouse') as env:
                apply_migrations(env)
                from sdk_protocol_acceptance import verify_sdk_protocol
                verify_sdk_protocol(binary('kansoku-server:exe:kansoku-server'),binary('kansoku-server:exe:kansoku-admin'),env,root / 'protocol',sdk)
                verify_identity_browser(binary('kansoku-server:exe:kansoku-server'), binary('kansoku-server:exe:kansoku-admin'), env, root / 'browser', sdk)
        finally:
            os.environ.clear(); os.environ.update(saved)


if __name__ == '__main__':
    main()
