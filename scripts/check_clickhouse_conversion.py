#!/usr/bin/env python3
"""Verify original byte ranges and every reviewed native adaptation without SQL."""
import hashlib
import json
import re
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


def verify_replicated():
    root = Path(__file__).resolve().parents[1] / 'kansoku-server/migrations'
    source, target = root / 'clickhouse', root / 'clickhouse-replicated'
    original = json.loads((source / 'manifest.json').read_text())
    manifest = json.loads((target / 'manifest.json').read_text())
    provenance = json.loads((target / 'provenance.json').read_text())
    assert manifest['component'] == 'kansoku_replicated'
    assert len(manifest['migrations']) == 25
    files = {item['file']: item for item in provenance['files']}
    omissions, adaptations = [], []
    for before, after in zip(original['migrations'], manifest['migrations'], strict=True):
        assert before['name'] == after['name']
        retained = []
        for step in before['steps']:
            data = (source / step['file']).read_bytes()
            if re.fullmatch(rb'\s*CREATE DATABASE IF NOT EXISTS analytics;?\s*', data):
                omissions.append(dict(migration=before['name'],step=step['name'],file=step['file'],sha256=hashlib.sha256(data).hexdigest()))
                continue
            adapted, count = re.subn(rb'\b(AggregatingMergeTree|ReplacingMergeTree)\b', rb'Replicated\1', data)
            if count:
                adaptations.append(dict(migration=before['name'],step=step['name'],count=count))
            if step['file'] == 'steps/0020_replay_safe_sessions/statement-03.sql':
                assert b"WHERE source='web' AND session_id!='' AND 0" in adapted
                syntax = provenance['syntaxAdaptations']
                assert len(syntax) == 1 and syntax[0]['file'] == step['file']
                assert syntax[0]['sourceSha256'] == hashlib.sha256(adapted).hexdigest()
                adapted = adapted.replace(b'\nAS\nSELECT',b'\nEMPTY AS\nSELECT')
                assert syntax[0]['sha256'] == hashlib.sha256(adapted).hexdigest()
            actual = (target / step['file']).read_bytes()
            assert actual == adapted, step['file']
            assert not re.search(rb'\b(?:ON\s+CLUSTER|CREATE\s+DATABASE|ENGINE\s*=\s*(?:Aggregating|Replacing)?MergeTree)\b', actual, re.I)
            assert files[step['file']] == dict(file=step['file'],sourceSha256=hashlib.sha256(data).hexdigest(),sha256=hashlib.sha256(actual).hexdigest())
            retained.append(step)
        assert after == dict(before, steps=retained)
    assert omissions == provenance['omissions'] and len(omissions) == 3
    assert adaptations == provenance['engineAdaptations'] and sum(x['count'] for x in adaptations) == 31
    assert len(files) == sum(len(m['steps']) for m in manifest['migrations']) == 254
    print('replicated conversion: 25 migrations, 254 steps, 3 omissions, 31 engine adaptations, 1 EMPTY modifier; all other bytes exact')


if __name__ == '__main__':
    verify()
    verify_replicated()
