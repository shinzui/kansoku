#!/usr/bin/env python3
"""Build the production CLI from workspace and published migration archives."""
import json
import os
import re
from pathlib import Path
import subprocess
import tarfile
import tempfile


def main():
    repo = Path(__file__).resolve().parents[1]
    migration_version = re.search(r'(?m)^\s*clickhouse-migrate ==([0-9.]+),', (repo / 'cabal.project').read_text()).group(1)
    os.umask(0o077)
    parent = repo / '.dev/acceptance'
    parent.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='ch-sdist-', dir=parent))
    archives = root / 'archives'
    archives.mkdir()
    workspace = root / 'workspace'
    workspace.mkdir()
    print('Private source archive evidence: ' + str(root), flush=True)
    def run(args, cwd=repo, env=None):
        result = subprocess.run(args,cwd=cwd,env=env,text=True,capture_output=True,timeout=900)
        with (root / 'commands.private').open('a') as output:
            output.write(result.stdout + result.stderr)
        result.check_returncode()
        return result.stdout.strip()
    run(['cabal','sdist','all','--output-directory',str(archives)])
    packages = []
    for archive in sorted(archives.glob('*.tar.gz')):
        with tarfile.open(archive) as source:
            top = source.getmembers()[0].name.split('/')[0]
            source.extractall(workspace,filter='data')
            packages.append(workspace / top)
    released = [name + '-' + migration_version for name in ['clickhouse-migrate', 'clickhouse-migrate-embed', 'clickhouse-migrate-cli', 'clickhouse-migrate-test-support']]
    run(['cabal','get','--pristine','--destdir',str(workspace),*released])
    packages.extend(workspace / name for name in released)
    required = {'kansoku-api-0.1.0.0', 'kansoku-core-0.1.0.0', 'kansoku-server-0.1.0.0', 'kansoku-client-0.1.0.0', 'ClickHaskell-1.1.0', 'hs-opentelemetry-instrumentation-servant-0.3.0.0'}
    required |= set(released)
    assert {path.name for path in packages} == required, 'Extract every workspace, pinned source-repository and published migration package'
    server = next(path for path in packages if path.name.startswith('kansoku-server-'))
    settings = (repo / 'cabal.project').read_text().split('index-state:',1)[1].split('source-repository-package',1)[0]
    (workspace / 'cabal.project').write_text('packages:\n' + ''.join('  '+str(path)+'\n' for path in packages) + '\nindex-state:' + settings)
    run(['clickhouse-migrate-embed-build','--input',str(server),'migrations/clickhouse/manifest.json','--input',str(server),'migrations/clickhouse-replicated/manifest.json','--','build','kansoku-server:exe:kansoku-ch-migrate'],workspace)
    binary = run(['cabal','list-bin','kansoku-server:exe:kansoku-ch-migrate'],workspace)
    (server / 'migrations').rename(root / 'withheld-migration-inputs')
    offline = {key:value for key,value in os.environ.items() if not key.startswith(('PG','CLICKHOUSE','KANSOKU_'))}
    document = json.loads(run([binary,'plan','--json'],root,offline))
    migrations = document['result']['components'][0]['migrations']
    assert len(migrations) == 26 and sum(len(item['steps']) for item in migrations[:25]) == 257 and len(migrations[-1]['steps']) == 7
    offline.update(KANSOKU_CH_MIGRATION_CLUSTER='fixture',KANSOKU_CH_MIGRATION_REPLICA_IDS='11111111-1111-4111-8111-111111111111,22222222-2222-4222-8222-222222222222')
    replicated = json.loads(run([binary,'plan','--json'],root,offline))['result']['components'][0]['migrations']
    assert len(replicated) == 26 and sum(len(item['steps']) for item in replicated[:25]) == 254 and len(replicated[-1]['steps']) == 7
    print('source archives: ' + str(len(packages)) + ' extracted packages built the production CLI; 26/264 direct and 26/261 replicated offline plans passed with inputs withheld',flush=True)


if __name__ == '__main__':
    main()
