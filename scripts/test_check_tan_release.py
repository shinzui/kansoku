"""Refuse plausible but mismatched release evidence before producing an artifact."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from check_tan_release import validate, GATES
from check_image_plans import PLAN_FIELDS, SELECTORS


class ReleaseValidation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.plans = Path(self.temp.name)
        self.report = dict(sourceRevision='a'*40, os='linux', architecture='amd64',
                           archiveSha256='b'*64, archiveConfigDigest='sha256:'+'c'*64,
                           imageId='sha256:'+'d'*64, layers=['sha256:'+'e'*64], replicatedSelectors=SELECTORS,
                           labels={'org.opencontainers.image.revision':'a'*40, 'org.opencontainers.image.source':'https://github.com/shinzui/kansoku'},
                           environmentMapping=True, explicitTlsValues=True, caBundle=True, fourExecutablePaths=True)
        for name, field in PLAN_FIELDS.items():
            if name == 'postgres.json':
                components = [dict(name='pgmq', migrations=[]), dict(name='kansoku', migrations=[dict(id=m) for m in ['kansoku/0008-clickhouse-replicated-administration', 'kansoku/0009-clickhouse-replicated-jobs']])]
            else:
                replicated = name == 'native-replicated.json'
                steps = 254 if replicated else 257
                components = [dict(name='kansoku_replicated' if replicated else 'kansoku', migrations=[dict(steps=[{}]*(steps-24))]+[dict(steps=[{}]) for _ in range(24)])]
            doc = dict(ok=True, data=dict(components=components)) if name == 'postgres.json' else dict(status='ok', result=dict(components=components, checksumFormats=['sha256-v2']))
            raw = json.dumps(doc).encode()+b'\n'
            (self.plans/name).write_bytes(raw)
            self.report[field] = hashlib.sha256(raw).hexdigest()
        candidate = {**self.report, 'cabalToolkitRevision':'f'*40, 'nixToolkitRevision':'f'*40, 'packageOutputs':['recorded-output'], 'buildEvidence':'private build receipt'}
        run = dict(status='passed', cases=5, failures=0, skips=0, sourceRevision='a'*40, toolkitRevision='f'*40, serverImage='digest', serverPlatform='linux/arm64', clientPlatform='darwin/arm64', artifactVariant='nix', command='owned gate', evidence='retained evidence')
        gates = {key:dict(status='accepted', reason='explicit residual risk', evidence=['retained'], owner='release owner', at='2026-11-08T01:00:00Z', decisionSource='actual decision record', candidateArchiveSha256=candidate['archiveSha256'], candidateImageId=candidate['imageId']) for key in GATES}
        self.evidence = dict(candidate=candidate, prerequisites={'62':copy.deepcopy(run),'63':copy.deepcopy(run)}, gates=gates, acceptanceRuns=[], publication=dict(image='gcr.io/tan-ng/kansoku@sha256:'+'1'*64, sourceRevision='a'*40, imageId=candidate['imageId'], uploadEvidence='receipt', readbackEvidence='receipt', verified=True, readback=copy.deepcopy(self.report)))

    def check(self, phase='published'):
        return validate(self.evidence, self.report, self.plans, phase)

    def test_valid_mapping(self):
        artifact, pending = self.check()
        self.assertFalse(pending)
        self.assertEqual(artifact['nativePlanSha256'], self.report['replicatedNativePlanSha256'])
        self.assertEqual(len(artifact), 8)

    def test_foreign_revision(self):
        self.report['sourceRevision'] = '2'*40
        with self.assertRaises(ValueError): self.check()

    def test_swapped_histories(self):
        c = self.evidence['candidate']
        c['nativePlanSha256'], c['replicatedNativePlanSha256'] = c['replicatedNativePlanSha256'], c['nativePlanSha256']
        with self.assertRaises(ValueError): self.check()

    def test_altered_bytes(self):
        with (self.plans/'postgres.json').open('ab') as out: out.write(b' ')
        with self.assertRaises(ValueError): self.check()

    def test_missing_prerequisite(self):
        del self.evidence['prerequisites']['62']
        with self.assertRaises(ValueError): self.check()

    def test_missing_decision_fields(self):
        for key in ['owner','at','reason','decisionSource']:
            with self.subTest(key=key):
                gate = self.evidence['gates']['managed-endpoint']
                saved = gate.pop(key)
                with self.assertRaises((ValueError, KeyError)): self.check()
                gate[key] = saved

    def test_configuration_id_is_not_manifest(self):
        self.evidence['publication']['image'] = 'gcr.io/tan-ng/kansoku@'+self.report['imageId']
        with self.assertRaises(ValueError): self.check()

    def test_pending_only_prepares_unusable_draft(self):
        self.evidence['gates']['managed-endpoint']['status'] = 'pending'
        self.evidence['publication'] = None
        artifact, pending = self.check('prepared')
        self.assertIsNone(artifact['image'])
        self.assertEqual(pending, ['managed-endpoint'])
        with self.assertRaises(ValueError): self.check()

    def test_failed_or_skipped_prerequisite(self):
        self.evidence['prerequisites']['63']['skips'] = 1
        with self.assertRaises(ValueError): self.check()

    def test_false_resolved_image_coverage(self):
        self.evidence['gates']['linux-amd64-image']['status'] = 'resolved'
        with self.assertRaises(ValueError): self.check()

    def test_decision_for_other_candidate(self):
        self.evidence['gates']['managed-endpoint']['candidateImageId'] = 'sha256:'+'9'*64
        with self.assertRaises(ValueError): self.check()


if __name__ == '__main__':
    unittest.main()
