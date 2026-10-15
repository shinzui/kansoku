#!/usr/bin/env python3
"""Run privacy assertions in separate processes because OTel memoizes semantics."""
import os
import subprocess

for mode in ('', 'http', 'http/dup'):
    print(f'HTTP semantic mode: {mode or "legacy"}', flush=True)
    env = dict(os.environ, OTEL_SEMCONV_STABILITY_OPT_IN=mode)
    subprocess.run(['cabal', 'test', 'kansoku-core-test', '--test-options=--match Kansoku.HttpTelemetry', '--test-show-details=direct'], env=env, check=True, timeout=120)

binary = subprocess.check_output(['cabal', 'list-bin', 'kansoku-core:test:kansoku-core-test'], text=True).strip()
for mode in ('normal', 'exception', 'disabled', 'unconfigured'):
    env = dict(os.environ, KANSOKU_TELEMETRY_LIFECYCLE_CHILD=mode, OTEL_TRACES_EXPORTER='console', OTEL_BSP_SCHEDULE_DELAY='60000', OTEL_METRICS_EXPORTER='none')
    env.pop('OTEL_SDK_DISABLED', None)
    env.pop('OTEL_EXPORTER_OTLP_ENDPOINT', None)
    if mode == 'disabled':
        env['OTEL_SDK_DISABLED'] = 'true'
    if mode == 'unconfigured':
        env.pop('OTEL_TRACES_EXPORTER', None)
        env.pop('OTEL_METRICS_EXPORTER', None)
    result = subprocess.run([binary], env=env, capture_output=True, text=True, check=True, timeout=15)
    exported = 'kansoku-lifecycle-flush-proof' in result.stdout
    assert exported == (mode in ('normal', 'exception')), (mode, result.stdout, result.stderr)
    print(f'Lifecycle {mode}: passed', flush=True)
