#!/usr/bin/env python3
"""Prepare a fresh owned Apple Container cluster for the reviewed Nagare drill.

Uses the local mode of mori://shinzui/nagare. Its stock k3d/Knative bootstrap
is outside this minimal, reviewed data-service fixture's coverage.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import urllib.request
import uuid

from nagare_maintenance_fixture import initialize_fixture, nagare, reviewed

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO/'test/fixtures/nagare-maintenance'
NODE = 'docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95'
LOCAL_PATH = ('https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml',
              '9781b39c24f3f651bd6d6e41b561e04e4904bbdb6d4f8c7a6009df3a702dcd65')
ASSETS = [
    ('server', 'minio', 'https://github.com/minio/minio/releases/download/RELEASE.2025-09-07T16-13-09Z/minio.linux-arm64.RELEASE.2025-09-07T16-13-09Z', '5c83cd2cf151717ba0243f73e1c7802ff36e272b67144bdd7f1f7d684fd6f03d'),
    ('client', 'mc', 'https://github.com/minio/mc/releases/download/RELEASE.2025-08-13T08-35-41Z/mc.linux-arm64.RELEASE.2025-08-13T08-35-41Z', '14c8c9616cfce4636add161304353244e8de383b2e2752c0e9dad01d4c27c12c'),
]
RUNNER = '''import json,os,sys
from pathlib import Path
root=Path(__file__).resolve().parent
binary=json.loads((root/'fixture.json').read_text())['nagarectl']
env={k:v for k,v in os.environ.items() if not k.startswith(('NAGARE_','CLOUDSDK_','PULUMI_')) and k not in ('KUBECONFIG','SOPS_AGE_KEY_FILE')}
env.update(NO_PROXY='127.0.0.1,localhost,0.0.0.0,192.168.0.0/16',no_proxy='127.0.0.1,localhost,0.0.0.0,192.168.0.0/16')
env.update(XDG_CONFIG_HOME=str(root/'config'),XDG_STATE_HOME=str(root/'state'),XDG_CACHE_HOME=str(root/'cache'),NAGARE_CONTEXT='local',KUBECONFIG=str(root/'config/nagare/kubeconfigs/local.yaml'))
os.execve(binary,[binary,'--context','local',*sys.argv[1:]],env)
'''


def run(*arguments):
    subprocess.run([str(arg) for arg in arguments], check=True, timeout=600)


def download(path, url, digest):
    with urllib.request.urlopen(url, timeout=120) as source, path.open('wb') as destination:
        shutil.copyfileobj(source, destination)
    assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, 'Fixture asset digest differs: '+url


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--nagarectl', type=Path, required=True)
    parser.add_argument('--nagare-source', type=Path, required=True, help='Canonical Mori-discovered Nagare checkout supplying its local MinIO manifest')
    args = parser.parse_args()
    os.umask(0o077)
    root = args.root.resolve()
    assert not root.exists(), 'A fresh root is required; failed owners remain available for recovery'
    root.mkdir(parents=True, mode=0o700)
    (root/'reviews').mkdir()
    config = root/'config/nagare/kubeconfigs/local.yaml'
    config.parent.mkdir(parents=True)
    cluster = 'kansoku-ep53-'+uuid.uuid4().hex[:8]
    fixture = dict(owner='kansoku-ep53', cluster=cluster, nodeImage=NODE, nagarectl=str(args.nagarectl.resolve()))
    (root/'fixture.json').write_text(json.dumps(fixture))
    (root/'run.py').write_text(RUNNER)
    nagare(root, 'context', 'create', 'local', '--mode', 'local', '--project', 'kansoku-ep53',
           '--registry-host', 'localhost:5000', '--base-domain', 'apps.localhost', '--target-platform', 'linux/arm64',
           '--local-object-store', 'http://minio.nagare-system.svc.cluster.local:9000/nagare-backups')
    (root/'nagare-version.json').write_text(nagare(root, 'version', '--json'))
    run('container', 'k8s', 'create', '--name', cluster, '--node-image', NODE, '--cpus', '6', '--memory', '12G')
    run('container', 'k8s', 'write-config', '--name', cluster, '--kubeconfig', config)
    kube = ['kubectl', '--kubeconfig', str(config)]
    run(*kube, 'config', 'rename-context', cluster, 'local')
    run(*kube, 'config', 'use-context', 'local')
    config.write_text(config.read_text().replace('https://0.0.0.0:', 'https://127.0.0.1:'))
    node = json.loads(subprocess.check_output(kube+['get', 'node', cluster, '-o', 'json']))
    fixture['nodeUID'] = node['metadata']['uid']
    (root/'fixture.json').write_text(json.dumps(fixture))
    foundation = json.loads((FIXTURES/'foundation.json').read_text())
    foundation['context']['project'] = 'kansoku-ep53'
    (root/'foundation.json').write_text(json.dumps(foundation))
    nagare(root, 'inventory', 'compile', '--input', str(root/'foundation.json'), '--out', str(root/'foundation-candidate'))
    nagare(root, 'inventory', 'plan', '--inventory', str(root/'foundation-candidate'), '--out', str(root/'reviews/foundation'))
    nagare(root, 'inventory', 'apply', str(root/'reviews/foundation'), '--yes')
    download(root/'local-path-storage.yaml', *LOCAL_PATH)
    run(*kube, 'apply', '-f', root/'local-path-storage.yaml')
    run(*kube, 'annotate', 'storageclass', 'local-path', 'storageclass.kubernetes.io/is-default-class=true')
    for tag, binary, url, digest in ASSETS:
        directory = root/'minio'/tag
        directory.mkdir(parents=True)
        download(directory/binary, url, digest)
        (directory/binary).chmod(0o755)
        dockerfile = 'FROM scratch\nCOPY minio /minio\nENTRYPOINT ["/minio"]\n' if tag == 'server' else 'FROM alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1\nCOPY mc /usr/local/bin/mc\n'
        (directory/'Dockerfile').write_text(dockerfile)
        image = 'kansoku-ep53-minio:'+tag
        run('container', 'build', '--tag', image, directory)
        run('container', 'k8s', 'load-image', '--name', cluster, image)
        run('container', 'exec', cluster, 'ctr', '--namespace', 'k8s.io', 'images', 'tag', image, 'docker.io/library/'+image)
    minio = (args.nagare_source/'cluster/local/minio/minio.yaml').read_text()
    minio = minio.replace('k3d-registry.localhost:5000/nagare-minio', 'docker.io/library/kansoku-ep53-minio:server')
    minio = minio.replace('k3d-registry.localhost:5000/nagare-mc', 'docker.io/library/kansoku-ep53-minio:client')
    (root/'minio.yaml').write_text(minio)
    run(*kube, 'apply', '-f', root/'minio.yaml')
    run(*kube, '-n', 'nagare-system', 'rollout', 'status', 'deployment/minio', '--timeout=180s')
    run(*kube, '-n', 'nagare-system', 'wait', '--for=condition=complete', 'job/minio-make-bucket', '--timeout=180s')
    run(*kube, 'apply', '-f', FIXTURES/'object-reader.json')
    for engine, name, memory in [('clickhouse', 'kansoku-ch', '4Gi'), ('postgres', 'kansoku-pg', '2Gi')]:
        command = ['db', 'create', engine, name, '-n', 'personal', '--memory', memory, '--size', '4Gi', '--recovery-backup', name+'-backup', '--recovery-key-version', 'v1']
        if engine == 'clickhouse':
            command += ['--version', '26.8.28.14']
        reviewed(root, 'create-'+engine, *command)
    shutil.copyfile(FIXTURES/'AppDatabases.hs', root/'AppDatabases.hs')
    reviewed(root, 'memberships', 'db', 'app-database', 'plan', '--config', str(root/'AppDatabases.hs'))
    initialize_fixture(root)
    print('Fresh reviewed local Nagare fixture prepared: '+str(root), flush=True)


if __name__ == '__main__':
    main()
