#!/usr/bin/env python3
"""Packaged writer proof; default is the required 600 seconds at 200 events/s."""
import argparse
import os
import subprocess
from test_support import binary, hspec

parser = argparse.ArgumentParser()
parser.add_argument('--smoke', action='store_true')
args = parser.parse_args()
subprocess.run(['cabal', 'build', 'kansoku-core:test:kansoku-core-test'], check=True)
package = subprocess.check_output(['nix', 'build', '.#kansoku-server', '--no-link', '--print-out-paths'], text=True).strip().splitlines()[-1]
env = {key: value for key, value in os.environ.items() if not key.startswith(('PG', 'CLICKHOUSE', 'KANSOKU_', 'OTEL_'))}
env.update(KANSOKU_PIPELINE_OUTAGE_CHILD='1', KANSOKU_OUTAGE_SECONDS='40' if args.smoke else '600',
           KANSOKU_OUTAGE_SERVER=package + '/bin/kansoku-server',
           KANSOKU_CH_MIGRATION_BINARY=package + '/bin/kansoku-ch-migrate',
           KANSOKU_PG_MIGRATION_BINARY=package + '/bin/kansoku-migrate')
hspec([binary('kansoku-core:test:kansoku-core-test')], env=env, timeout=1800)
