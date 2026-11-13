"""Actual backup producer for an owned direct migration fixture."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import time
import uuid


def prepare_entry(h, executable, arguments, predecessor, produce_drain, qualified):
    extra = [arg for arg in arguments if arg.startswith('--proof-')]
    command = next((arg for arg in arguments if arg in ('up','repair')), None)
    context = None
    needed = False
    if command:
        context = json.loads(h.run([executable,*extra,'maintenance','recovery-context','--json']).stdout)['result']
        needed = context['predecessor'] == predecessor and not context['retainedRecoverySet'] and context['pendingSql'] and (context['compatible'] or command == 'repair')
    if qualified:
        # App-scoped background controls; never pause the shared server.
        names = h.sql("SELECT name FROM system.tables WHERE database='analytics' AND position(engine,'MergeTree')>0 ORDER BY name").strip().splitlines()
        for name in names:
            h.sql('SYSTEM STOP TTL MERGES analytics.`'+name.replace('`','``')+'`')
        deadline = time.monotonic() + 60
        while h.sql("SELECT (SELECT count() FROM system.mutations WHERE database='analytics' AND NOT is_done)+(SELECT count() FROM system.merges WHERE database='analytics')").strip() != '0':
            assert time.monotonic() < deadline, 'owned background changes failed to settle before drain evidence'
            time.sleep(.1)
    elif needed:
        raise AssertionError('Cannot produce a new recovery set without established predecessor drain')
    evidence, settings = produce_drain()
    if not needed:
        return settings, None
    assert context['fenced'] and context['predecessor'] == predecessor
    root = h.root/('recovery-set-'+uuid.uuid4().hex)
    root.mkdir(mode=0o700)
    start = datetime.now(timezone.utc).isoformat()
    dump = root/'postgres.dump'
    h.run(['pg_dump','--format=custom','--file',str(dump)])
    pg_done = datetime.now(timezone.utc).isoformat()
    name = root.name+'.zip'
    status = h.sql("BACKUP DATABASE analytics, DATABASE kansoku_migration_ledger TO Disk('kansoku_backups','"+name+"')")
    assert status.strip().split('\t')[-1] == 'BACKUP_CREATED'
    ch_done = datetime.now(timezone.utc).isoformat()
    archive = Path(settings['KANSOKU_OWNED_CLICKHOUSE_BACKUP_ROOT'])/name
    pg_receipt = root/'postgres.receipt'
    pg_receipt.write_text(json.dumps(dict(exitCode=0,format='pg_dump custom')))
    ch_receipt = root/'clickhouse.receipt'
    ch_receipt.write_text(status)
    def snapshot(store,database,began,done,artifact,receipt):
        return dict(store=store,database=database,startedAt=began,completedAt=done,artifactReference=str(artifact),artifactSha256=hashlib.sha256(artifact.read_bytes()).hexdigest(),verificationReference=str(receipt),verificationSha256=hashlib.sha256(receipt.read_bytes()).hexdigest(),complete=True)
    manifest = {key:context[key] for key in ['target','servers','ledger','session','predecessor','planSha256','postgresDatabase','retentionPolicy','coordinatorState']}
    manifest.update(schemaVersion=1,id=str(uuid.uuid4()),drainSha256=hashlib.sha256(evidence.read_bytes()).hexdigest(),stableFrom=start,stableUntil=json.loads(evidence.read_text())['expiresAt'],coordinatorSnapshotPhase='fenced-before-native-entry',backgroundChangesSettled=True,operatorAttested=True,snapshots=[snapshot('postgresql',context['postgresDatabase'],start,pg_done,dump,pg_receipt),snapshot('clickhouse','analytics',pg_done,ch_done,archive,ch_receipt),snapshot('clickhouse','kansoku_migration_ledger',pg_done,ch_done,archive,ch_receipt)])
    path = root/'manifest.json'
    path.write_text(json.dumps(manifest))
    return settings, path
