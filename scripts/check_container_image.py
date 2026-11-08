#!/usr/bin/env python3
"""Check an exported image in an explicit local Docker context, without database access."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import uuid
from check_image_plans import PLAN_FIELDS, SELECTORS, validate_plan


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--engine', choices=['apple', 'docker'], default='apple')
    parser.add_argument('--docker-context')
    parser.add_argument('--oci-archive', type=Path, help='Equivalent OCI archive for Apple Container')
    parser.add_argument('--revision', required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--plan-dir', type=Path, required=True)
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
    if args.engine == 'apple':
        if not args.oci_archive or str(args.oci_archive.resolve()).startswith('/nix/store/'):
            raise SystemExit('Apple Container requires --oci-archive exported to a normal file')
        subprocess.run(['container', 'image', 'load', '--input', str(args.oci_archive)], check=True, capture_output=True, timeout=120)
        loaded = json.loads(subprocess.check_output(['container', 'image', 'inspect', expected], timeout=30))[0]
        variants = loaded['variants']
        if len(variants) != 1 or variants[0]['platform'] != {'architecture': 'amd64', 'os': 'linux'}:
            raise RuntimeError('Expected exactly one Linux amd64 variant')
        loaded_config = variants[0]['config']
        image_id = 'sha256:' + loaded['id']
        host_architecture = 'arm64'
        image_id_kind = 'Apple Container local OCI index digest; not a published registry digest'
    else:
        if not args.docker_context:
            raise SystemExit('Docker requires an explicit local --docker-context')
        docker = ['docker', '--context', args.docker_context]
        context = json.loads(subprocess.check_output(docker + ['context', 'inspect', args.docker_context], text=True))[0]
        if not context['Endpoints']['docker']['Host'].startswith('unix://'):
            raise SystemExit('An explicit local Unix Docker context is required')
        subprocess.run(docker + ['load', '-i', str(archive_path)], check=True, capture_output=True, timeout=120)
        loaded = json.loads(subprocess.check_output(docker + ['image', 'inspect', expected], text=True))[0]
        loaded_config = {'rootfs': {'diff_ids': loaded['RootFS']['Layers']}, 'config': loaded['Config']}
        image_id = loaded['Id']
        host_architecture = subprocess.check_output(docker + ['info', '--format', '{{.Architecture}}'], text=True, timeout=15).strip()
        image_id_kind = 'Docker loaded configuration ID; not a published registry digest'
    if loaded_config['rootfs']['diff_ids'] != config['rootfs']['diff_ids'] or any(
            loaded_config['config'].get(key) != config['config'].get(key)
            for key in ['Entrypoint', 'Cmd', 'Env', 'Labels']):
        raise RuntimeError('Loaded image differs from the exported artifact')
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
            if args.engine == 'apple':
                subprocess.run(['container', 'create', '--name', name, '--network', 'none', '--no-dns',
                    '--rosetta', '--platform', 'linux/amd64', '--memory', '2G', *flags, expected, *command],
                    check=True, capture_output=True, timeout=30)
                created = json.loads(subprocess.check_output(['container', 'inspect', name], timeout=15))[0]['configuration']
                if (created['image']['descriptor']['digest'] != image_id or created['networks'] or created['mounts']
                        or created['platform'] != {'architecture': 'amd64', 'os': 'linux'}):
                    raise RuntimeError('Created container identity/isolation differs')
                result = subprocess.run(['container', 'start', '--attach', name], capture_output=True, timeout=60)
            else:
                result = subprocess.run(docker + ['run', '--name', name, '--rm', '--network', 'none',
                    '--platform', 'linux/amd64', '--pull=never', *flags, image_id, *command],
                    capture_output=True, timeout=60)
            if (result.returncode == 0) != success:
                raise RuntimeError('Owned image probe failed: ' + ' '.join(command) + ' (exit ' + str(result.returncode) + '): ' + result.stderr[-2000:].decode(errors='replace'))
            return result.stdout if success else result.stderr
        finally:
            cleanup = ['container', 'delete', '--force', name] if args.engine == 'apple' else docker + ['rm', '--force', name]
            subprocess.run(cleanup, capture_output=True, timeout=15)

    captures = {}
    for filename in PLAN_FIELDS:
        env = {**supplied, **SELECTORS} if filename == 'native-replicated.json' else supplied
        command = 'kansoku-migrate' if filename == 'postgres.json' else 'kansoku-ch-migrate'
        raw = run(env, command, 'plan', '--json')
        validate_plan(filename, raw)
        if raw != run(env, command, 'plan', '--json'):
            raise RuntimeError('Plan output is not byte-repeatable: ' + filename)
        captures[filename] = raw
    reference = Path(__file__).resolve().parents[1] / 'kansoku-server/test/fixtures/clickhouse-direct-plan-2008b67.json'
    if json.loads(captures['native-direct.json']) != json.loads(reference.read_bytes()):
        raise RuntimeError('Direct history changed from the retained compatibility fixture')
    args.plan_dir.mkdir(parents=True, exist_ok=True)
    for filename, raw in captures.items():
        destination = args.plan_dir / filename
        with destination.open('xb') as output:
            output.write(raw)
    mapped = dict(row.split('=', 1) for row in run(supplied, 'env').decode().splitlines() if '=' in row)
    for key, origin in {'PG_CONNECTION_STRING': 'DATABASE_URL', 'KANSOKU_CLICKHOUSE_HOST': 'CLICKHOUSE_HOST',
                        'KANSOKU_CLICKHOUSE_USER': 'CLICKHOUSE_USER', 'KANSOKU_CLICKHOUSE_PASSWORD': 'CLICKHOUSE_PASSWORD'}.items():
        if mapped[key] != supplied[origin]:
            raise RuntimeError('Entrypoint mapping failed: ' + key)
    if mapped['KANSOKU_CLICKHOUSE_SECURE'] != 'true' or mapped['CLICKHOUSE_TCP_PORT'] != '9440':
        raise RuntimeError('Explicit native TLS values were lost')
    mapped = dict(row.split('=', 1) for row in run({**supplied, **explicit}, 'env').decode().splitlines() if '=' in row)
    if any(mapped[key] != value for key, value in explicit.items()):
        raise RuntimeError('Explicit application settings did not win')
    missing = run({key: value for key, value in supplied.items() if key != 'DATABASE_URL'}, 'env', success=False)
    if b'DATABASE_URL is not set' not in missing:
        raise RuntimeError('Missing environment failed for an unexpected reason')
    run(supplied, 'sh', '-c', 'for name in kansoku-server kansoku-migrate kansoku-ch-migrate kansoku-admin; do command -v "$name" >/dev/null || exit 1; done; test -s "$SSL_CERT_FILE"')
    report = {'sourceRevision': args.revision, 'tag': expected, 'imageId': image_id, 'archiveConfigDigest': config_digest,
              'architecture': 'amd64', 'os': 'linux', 'dockerHostArchitecture': host_architecture,
              'clientExecution': 'native' if host_architecture in ('amd64', 'x86_64') else 'emulated', 'migrationCount': len(json.loads(captures['native-direct.json'])['result']['components'][0]['migrations']), 'stepCount': sum(len(m['steps']) for m in json.loads(captures['native-direct.json'])['result']['components'][0]['migrations']),
              **{field: hashlib.sha256(captures[name]).hexdigest() for name, field in PLAN_FIELDS.items()},
              'replicatedSelectors': SELECTORS, 'hashSemantics': 'SHA-256 of exact stdout bytes including final newline',
              'archiveSha256': hashlib.file_digest(archive_path.open('rb'), 'sha256').hexdigest(),
              'layers': loaded_config['rootfs']['diff_ids'], 'labels': labels,
              'engine': args.engine, 'imageIdKind': image_id_kind,
              'ociArchiveSha256': hashlib.file_digest(args.oci_archive.open('rb'), 'sha256').hexdigest() if args.oci_archive else None,
              'environmentMapping': True, 'explicitTlsValues': True, 'caBundle': True,
              'fourExecutablePaths': True, 'scope': 'Network-disabled exported-image smoke only; no database, managed-target or event-flow acceptance'}
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
