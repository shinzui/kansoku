#!/usr/bin/env python3
"""Validate retained release evidence; never infer human approval or contact targets.

Exit 0: requested phase validated. Exit 1: invalid evidence. Exit 2: valid
preparation whose published readiness still has pending gates.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
from check_image_plans import PLAN_FIELDS, SELECTORS, validate_plan

GATES = {'startup-crash', 'security-patch-review', 'linux-amd64-image', 'managed-endpoint'}
HEX = r'[0-9a-f]{64}'


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def validate(evidence, report, plan_dir, phase):
    candidate = evidence['candidate']
    revision = candidate['sourceRevision']
    require(re.fullmatch(r'[0-9a-f]{40}', revision) is not None, 'Clean full source revision required')
    require(report['sourceRevision'] == revision, 'Foreign image source revision')
    require(candidate['cabalToolkitRevision'] == candidate['nixToolkitRevision'], 'Dependency pins disagree')
    require(re.fullmatch(r'[0-9a-f]{40}', candidate['cabalToolkitRevision']) is not None, 'Full toolkit revision required')
    require((report['os'], report['architecture']) == ('linux', 'amd64'), 'Expected Linux amd64')
    if phase == 'published':
        require(isinstance(evidence.get('publication'), dict), 'Publication receipts required')
    identity = candidate if phase == 'prepared' else evidence['publication']['readback']
    for key in ['archiveSha256', 'archiveConfigDigest', 'imageId', 'layers']:
        require(identity[key] == report[key], 'Candidate/readback image mismatch: ' + key)
    require(candidate['layers'] == report['layers'], 'Readback filesystem layers differ')
    for key in ['archiveConfigDigest', 'imageId']:
        require(re.fullmatch('sha256:' + HEX, candidate[key]) is not None, 'Invalid ' + key)
    require(re.fullmatch(HEX, candidate['archiveSha256']) is not None, 'Invalid archive hash')
    require(candidate['packageOutputs'] and candidate['buildEvidence'], 'Missing build identities')
    require(report['replicatedSelectors'] == SELECTORS, 'Unexpected offline selectors')
    require(report['labels']['org.opencontainers.image.revision'] == revision and
            report['labels']['org.opencontainers.image.source'] == 'https://github.com/shinzui/kansoku', 'Invalid OCI labels')
    for flag in ['environmentMapping', 'explicitTlsValues', 'caBundle', 'fourExecutablePaths']:
        require(report[flag] is True, 'Missing image smoke: ' + flag)
    for name, field in PLAN_FIELDS.items():
        raw = (plan_dir / name).read_bytes()
        validate_plan(name, raw)
        digest = hashlib.sha256(raw).hexdigest()
        require(digest == report[field] == candidate[field], 'Plan bytes/hash mismatch: ' + name)
    require(set(evidence['prerequisites']) == {'62', '63'}, 'Missing prerequisite evidence')
    for plan, run in evidence['prerequisites'].items():
        require(run['status'] == 'passed' and run['cases'] > 0 and run['failures'] == 0 and run['skips'] == 0,
                'Prerequisite did not pass: ' + plan)
        for key in ['sourceRevision', 'toolkitRevision', 'serverImage', 'serverPlatform', 'clientPlatform', 'artifactVariant', 'command', 'evidence']:
            require(bool(run[key]), 'Missing prerequisite field: ' + key)
        require(run['toolkitRevision'] == candidate['cabalToolkitRevision'], 'Prerequisite toolkit mismatch')
    require(set(evidence['gates']) == GATES, 'Incomplete gate set')
    pending = []
    for key, gate in evidence['gates'].items():
        require(gate['status'] in {'pending', 'accepted', 'resolved'}, 'Invalid gate status')
        require(bool(gate['reason']) and bool(gate['evidence']), 'Gate needs reason and evidence: ' + key)
        if gate['status'] == 'pending':
            pending.append(key)
        if gate['status'] == 'accepted':
            for field in ['owner', 'at', 'decisionSource']:
                require(bool(gate.get(field)), 'Missing owner decision ' + field)
            at = datetime.fromisoformat(gate['at'].replace('Z', '+00:00'))
            require(at.utcoffset() is not None and at.utcoffset().total_seconds() == 0, 'Decision date must be UTC')
            require(gate['candidateArchiveSha256'] == candidate['archiveSha256'] and
                    gate['candidateImageId'] == candidate['imageId'], 'Decision covers another candidate')
        if key == 'managed-endpoint':
            require(gate['status'] != 'resolved', 'Managed endpoint requires explicit owner acceptance')
    for run in evidence['acceptanceRuns']:
        require(run['sourceRevision'] == revision and run['toolkitRevision'] == candidate['cabalToolkitRevision'], 'Foreign acceptance run')
        require(run['imageId'] == candidate['imageId'], 'Acceptance ran another image')
        require(run['cases'] > 0 and run['failures'] == 0 and run['skips'] == 0, 'Nonpassing acceptance run')
    if evidence['gates']['linux-amd64-image']['status'] == 'resolved':
        families = {r['family'] for r in evidence['acceptanceRuns'] if r['clientPlatform'] == 'linux/amd64' and r.get('complete') is True}
        require({'migrations', 'runtime'} <= families, 'Missing full image behavioral acceptance')
    image = (evidence.get('publication') or {}).get('image')
    if phase == 'published':
        require(not pending, 'Pending release gates: ' + ', '.join(sorted(pending)))
        publication = evidence['publication']
        require(isinstance(image, str) and re.fullmatch(r'gcr.io/tan-ng/kansoku@sha256:' + HEX, image), 'Registry manifest reference required')
        require(image.split('@')[1] not in {candidate['imageId'], candidate['archiveConfigDigest'], 'sha256:' + candidate['archiveSha256']}, 'Configuration/archive ID is not a registry manifest')
        require(publication['readbackEvidence'] and publication['uploadEvidence'] and publication['verified'] is True, 'Missing publication/readback receipts')
        require(publication['sourceRevision'] == revision and publication['imageId'] == report['imageId'], 'Foreign readback identity')
    else:
        # A draft deliberately cannot be copied as a digest-addressed deployment input.
        image = None
    artifact = dict(image=image, sourceProject='mori://shinzui/kansoku',
                    sourcePackage='mori://shinzui/kansoku/packages/kansoku-server',
                    sourceRevision=revision, upstreamProject='mori://shinzui/clickhouse-migrate',
                    upstreamImplementation=candidate['cabalToolkitRevision'],
                    nativePlanSha256=candidate['replicatedNativePlanSha256'],
                    postgresPlanSha256=candidate['postgresPlanSha256'])
    return artifact, sorted(pending)


def verify_source(evidence):
    """Bind claimed pins/prerequisites to the committed image source in this repo."""
    repo = Path(__file__).resolve().parents[1]
    candidate = evidence['candidate']
    revision = candidate['sourceRevision']
    require(re.fullmatch(r'[0-9a-f]{40}', revision) is not None, 'Full source revision required')
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=repo, timeout=15).decode()
    for path, key in [('cabal.project', 'cabalToolkitRevision'), ('flake.module.nix', 'nixToolkitRevision')]:
        require(candidate[key] in git('show', revision + ':' + path), 'Pin absent from committed ' + path)
    for run in evidence['prerequisites'].values():
        subprocess.run(['git', 'merge-base', '--is-ancestor', run['sourceRevision'], revision], cwd=repo, check=True, timeout=15)
    matrix = json.loads(git('show', revision + ':db/clickhouse/qualification/matrix.json'))
    require(evidence['target'] == matrix['deploymentTargets'][0], 'Target differs from candidate matrix')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['evidence', 'artifact', 'image-report', 'plan-dir']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--phase', choices=['prepared', 'published'], required=True)
    args = parser.parse_args()
    try:
        evidence = json.loads(args.evidence.read_bytes())
        verify_source(evidence)
        artifact, pending = validate(evidence, json.loads(args.image_report.read_bytes()), args.plan_dir, args.phase)
        if args.artifact.exists():
            require(json.loads(args.artifact.read_bytes()) == artifact, 'Existing artifact mapping differs; preserve it and select a new output path')
        else:
            with args.artifact.open('x') as out:
                out.write(json.dumps(artifact, indent=2) + '\n')
        print(json.dumps(dict(phase=args.phase, image=artifact['image'], sourceRevision=artifact['sourceRevision'], pendingGates=pending)))
        return 2 if pending else 0
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        print('Release validation failed: ' + str(error))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
