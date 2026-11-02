#!/usr/bin/env python3
"""Prove pinned embedding from the server sdist observes preserved-time SQL changes."""
import json
import os
import re
from pathlib import Path
import subprocess
import tarfile
import tempfile


def main():
    repo = Path(__file__).resolve().parents[1]
    project = (repo / 'cabal.project').read_text()
    migration_version = re.search(r'(?m)^\s*clickhouse-migrate ==([0-9.]+),', project).group(1)
    os.umask(0o077)
    parent = repo / '.dev/acceptance'
    parent.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='ch-embedding-', dir=parent))
    print('Private embedding evidence: ' + str(root), flush=True)
    def run(args, cwd=repo):
        result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=600)
        with (root / 'commands.private').open('a') as output:
            output.write(result.stdout + result.stderr)
        result.check_returncode()
        return result.stdout.strip()
    run(['cabal', 'sdist', 'kansoku-server', '--output-directory', str(root)])
    archive = root / 'kansoku-server-0.1.0.0.tar.gz'
    with tarfile.open(archive) as source:
        source.extractall(root, filter='data')
    package = root / 'kansoku-server-0.1.0.0'
    (package / 'proof').mkdir()
    (package / 'proof/Main.hs').write_text('''module Main where
import Kansoku.ClickHouseMigrations qualified as M
import ClickHouseMigrate.Plan
import Data.List.NonEmpty qualified as NE
main = either (fail . show) (mapM_ (print . migrationChecksumHex . migrationChecksum) . NE.toList . inspectSchedule) M.plan
''')
    (package / 'kansoku-server.cabal').write_text('''cabal-version: 3.12
name: kansoku-server
version: 0.1.0.0
build-type: Simple
executable embedding-proof
  default-language: GHC2024
  default-extensions: OverloadedStrings
  hs-source-dirs: proof src
  main-is: Main.hs
  other-modules: Kansoku.ClickHouseMigrations
  build-depends: base >=4.21 && <4.22, bytestring, text, clickhouse-migrate ==MIGRATION_VERSION, clickhouse-migrate-embed ==MIGRATION_VERSION
'''.replace('MIGRATION_VERSION', migration_version))
    (package / 'cabal.project').write_text('packages: .\n' + project[project.index('index-state:'):])
    build = ['clickhouse-migrate-embed-build', '--input', '.', 'migrations/clickhouse/manifest.json', '--', 'build', 'all']
    run(build, package)
    binary = run(['cabal', 'list-bin', 'embedding-proof'], package)
    original = run([binary], package)
    manifest = json.loads((package / 'migrations/clickhouse/manifest.json').read_text())
    sql = package / 'migrations/clickhouse' / manifest['migrations'][-1]['steps'][-1]['file']
    stat = sql.stat()
    sql.write_bytes(sql.read_bytes() + b'\n-- preserved timestamp embedding proof\n')
    os.utime(sql, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    run(build, package)
    changed = run([binary], root)
    assert original != changed and len(changed.splitlines()) == 25
    # Remove all inputs from the extracted source, then run the compiled result.
    (package / 'migrations').rename(root / 'withheld-inputs')
    assert run([binary], root) == changed
    print('embedding: extracted server archive compiled; preserved-time change rebuilt; source-free inspection passed', flush=True)


if __name__ == '__main__':
    main()
