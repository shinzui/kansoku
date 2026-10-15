#!/usr/bin/env python3
"""Resolve and exercise the actual registered browser SDK without modifying it."""
import os
from pathlib import Path
import subprocess

uri = 'mori://shinzui/kansoku-ts/packages/kansoku-js'
resolved = subprocess.check_output(['mori', 'path', uri], text=True).splitlines()
source = Path(resolved[-1])
assert source.is_dir(), 'Mori did not return the SDK package directory'
revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
env = dict(os.environ, KANSOKU_TS_SOURCE=str(source))
subprocess.run(['bun', 'run', 'scripts/sdk-rate-limit.ts'], env=env, check=True, timeout=30)
print(f'Consumer source: {uri} at {revision}', flush=True)
