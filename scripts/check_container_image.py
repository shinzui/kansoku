#!/usr/bin/env python3
"""Check an exported image in an explicit local Docker context, without database access."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--docker-context', required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    archive_path = args.archive.resolve()
    if str(archive_path).startswith('/nix/store/'):
        raise SystemExit('Export the image with the stream app into a normal artifact file first')
    with tarfile.open(archive_path) as archive:
        manifest = json.load(archive.extractfile('manifest.json'))
        if len(manifest) != 1:
            raise SystemExit('Exactly one image is required')
        config_bytes = archive.extractfile(manifest[0]['Config']).read()
        config = json.loads(config_bytes)
    expected = 'gcr.io/tan-ng/kansoku:' + args.revision[:12] + '-p1'
    if manifest[0]['RepoTags'] != [expected]:
        raise SystemExit('Unexpected source tag')
    labels = config['config'].get('Labels', {})
    if labels.get('org.opencontainers.image.revision') != args.revision:
        raise SystemExit('Unexpected source revision')
    if labels.get('org.opencontainers.image.source') != 'https://github.com/shinzui/kansoku':
        raise SystemExit('Unexpected source repository')
    if (config['architecture'], config['os']) != ('amd64', 'linux'):
        raise SystemExit('Expected Linux amd64')
    if config['config']['Entrypoint'] != ['/entrypoint.sh'] or config['config']['Cmd'] != ['kansoku-server']:
        raise SystemExit('Unexpected entrypoint or default command')
    config_digest = 'sha256:' + hashlib.sha256(config_bytes).hexdigest()
    docker = ['docker', '--context', args.docker_context]
    context = json.loads(subprocess.check_output(docker + ['context', 'inspect', args.docker_context], text=True))[0]
    if not context['Endpoints']['docker']['Host'].startswith('unix://'):
        raise SystemExit('An explicit local Unix Docker context is required')
    subprocess.run(docker + ['load', '-i', str(archive_path)], check=True, capture_output=True, timeout=120)
    loaded = json.loads(subprocess.check_output(docker + ['image', 'inspect', expected], text=True))[0]
    if loaded['RootFS']['Layers'] != config['rootfs']['diff_ids'] or any(
            loaded['Config'].get(key) != config['config'].get(key)
            for key in ['Entrypoint', 'Cmd', 'Env', 'Labels']):
        raise RuntimeError('Loaded image differs from the exported artifact')
    # Docker may normalize legacy archive configuration when assigning its ID.
    # Bind the loaded filesystem/configuration, then execute that recorded ID.
    image_id = loaded['Id']
    supplied = {
        'DATABASE_URL': 'postgresql://image-proof@pg/kansoku',
        'CLICKHOUSE_HOST': 'owned-clickhouse',
        'CLICKHOUSE_USER': 'image-proof',
        'CLICKHOUSE_PASSWORD': 'image-proof-only',
        'KANSOKU_CLICKHOUSE_SECURE': 'true',
        'CLICKHOUSE_TCP_PORT': '9440',
    }
    explicit = {
        'PG_CONNECTION_STRING': 'postgresql://explicit@pg/explicit',
        'KANSOKU_CLICKHOUSE_HOST': 'explicit-host',
        'KANSOKU_CLICKHOUSE_USER': 'explicit-user',
        'KANSOKU_CLICKHOUSE_PASSWORD': 'explicit-proof-only',
    }

    def run(env, *command, success=True):
        name = 'kansoku-image-proof-' + uuid.uuid4().hex
        flags = [item for key, value in env.items() for item in ['-e', key + '=' + value]]
        try:
            result = subprocess.run(docker + ['run', '--name', name, '--rm', '--network', 'none',
                '--platform', 'linux/amd64', '--pull=never', *flags, image_id, *command],
                text=True, capture_output=True, timeout=60)
            if (result.returncode == 0) != success:
                raise RuntimeError('Owned image probe failed: ' + ' '.join(command) + ' (exit ' + str(result.returncode) + '): ' + result.stderr[-2000:])
            return result.stdout if success else result.stderr
        finally:
            subprocess.run(docker + ['rm', '--force', name], capture_output=True, timeout=15)

    plan_text = run(supplied, 'kansoku-ch-migrate', 'plan', '--json')
    plan = json.loads(plan_text)
    migrations = plan['result']['components'][0]['migrations']
    if plan['status'] != 'ok' or len(migrations) != 25 or sum(len(item['steps']) for item in migrations) != 257:
        raise RuntimeError('Unexpected embedded migration plan')
    mapped = dict(row.split('=', 1) for row in run(supplied, 'env').splitlines() if '=' in row)
    for key, origin in {'PG_CONNECTION_STRING': 'DATABASE_URL', 'KANSOKU_CLICKHOUSE_HOST': 'CLICKHOUSE_HOST',
                        'KANSOKU_CLICKHOUSE_USER': 'CLICKHOUSE_USER', 'KANSOKU_CLICKHOUSE_PASSWORD': 'CLICKHOUSE_PASSWORD'}.items():
        if mapped[key] != supplied[origin]:
            raise RuntimeError('Entrypoint mapping failed: ' + key)
    if mapped['KANSOKU_CLICKHOUSE_SECURE'] != 'true' or mapped['CLICKHOUSE_TCP_PORT'] != '9440':
        raise RuntimeError('Explicit native TLS values were lost')
    mapped = dict(row.split('=', 1) for row in run({**supplied, **explicit}, 'env').splitlines() if '=' in row)
    if any(mapped[key] != value for key, value in explicit.items()):
        raise RuntimeError('Explicit application settings did not win')
    missing = run({key: value for key, value in supplied.items() if key != 'DATABASE_URL'}, 'env', success=False)
    if 'DATABASE_URL is not set' not in missing:
        raise RuntimeError('Missing environment failed for an unexpected reason')
    run(supplied, 'sh', '-c', 'for name in kansoku-server kansoku-migrate kansoku-ch-migrate kansoku-admin; do command -v "$name" >/dev/null || exit 1; done; test -s "$SSL_CERT_FILE"')
    report = {'sourceRevision': args.revision, 'tag': expected, 'imageId': image_id, 'archiveConfigDigest': config_digest,
              'architecture': 'amd64', 'os': 'linux', 'migrationCount': 25, 'stepCount': 257,
              'nativePlanSha256': hashlib.sha256(plan_text.encode()).hexdigest(),
              'environmentMapping': True, 'explicitTlsValues': True, 'caBundle': True,
              'fourExecutablePaths': True, 'scope': 'Network-disabled exported-image smoke only; no database, managed-target or event-flow acceptance'}
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
