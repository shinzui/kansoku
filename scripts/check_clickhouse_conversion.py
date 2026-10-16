#!/usr/bin/env python3
"""Verify original byte ranges and every reviewed native adaptation without SQL."""
import hashlib
import json
from pathlib import Path


def verify():
    root = Path(__file__).resolve().parents[1]
    converted = root / 'kansoku-server/migrations/clickhouse'
    provenance = json.loads((converted / 'provenance.json').read_text())
    manifest = json.loads((converted / 'manifest.json').read_text())
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    assert len(provenance['files']) == len(manifest['migrations']) == 25
    expected = {}
    for source in provenance['files']:
        original = (converted / source['original']).read_bytes()
        assert original == (root / source['sourcePath']).read_bytes()
        assert hashlib.sha256(original).hexdigest() == source['sha256']
        chunks = []
        for step in source['steps']:
            path = converted / step['file']
            assert digest(path) == step['sha256']
            assert path.read_bytes() == original[step['byteStart']:step['byteEndExclusive']]
            chunks.append(path.read_bytes())
            expected[(source['migration'], step['name'])] = step['file']
        assert b''.join(chunks) == original
    assert len(expected) == 253
    assert len(provenance['nativeAdaptations']) == 3
    for adaptation in provenance['nativeAdaptations']:
        source = adaptation['sourceStep']
        assert digest(converted / source['file']) == adaptation['sourceStepSha256']
        identity = next(key for key, path in expected.items() if path == source['file'])
        del expected[identity]
        for step in adaptation['nativeSteps']:
            assert digest(converted / step['file']) == step['sha256']
            expected[(identity[0], step['name'])] = step['file']
    actual = {(m['name'], s['name']): s['file'] for m in manifest['migrations'] for s in m['steps']}
    assert actual == expected and len(actual) == 257
    assert [m['name'] for m in manifest['migrations']] == [f['migration'] for f in provenance['files']]
    runner = provenance['runner']
    assert digest(converted / runner['fixturePath']) == runner['sha256']
    print('conversion: 25 files, 253 exact original ranges, 3 reviewed adaptations, 257 native steps')


if __name__ == '__main__':
    verify()
