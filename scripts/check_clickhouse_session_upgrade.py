#!/usr/bin/env python3
"""Apply 0008 to a real 2008b67 session without losing its persistent fence."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import uuid
from isolated_postgres import isolated_postgres


def main():
    parser = argparse.ArgumentParser()
    for flag in ['old-pg','old-native','pg','native']:
        parser.add_argument('--'+flag,required=True)
    args=parser.parse_args()
    Path('.dev/acceptance').mkdir(parents=True,exist_ok=True)
    root=Path(tempfile.mkdtemp(prefix='session-upgrade-',dir='.dev/acceptance')).resolve()
    with isolated_postgres(root/'postgres') as env:
        env.update(KANSOKU_CH_MIGRATION_TARGET='kansoku/owned-upgrade',KANSOKU_CH_MIGRATION_SERVER_ID=str(uuid.uuid4()),KANSOKU_CH_MIGRATION_LEDGER_ID=str(uuid.uuid4()),KANSOKU_CH_MIGRATION_ENDPOINT='http://127.0.0.1:1',KANSOKU_CLICKHOUSE_PASSWORD='unused')
        def run(command,success=True,selected=None):
            result=subprocess.run(command,env=selected or env,capture_output=True,text=True,timeout=60)
            with (root/'commands.private').open('a') as output: output.write(result.stdout+result.stderr)
            assert (result.returncode==0)==success
            return result.stdout
        run([args.old_pg,'up'])
        report=json.loads(run([args.old_native,'maintenance','begin','--json','--expect-target',env['KANSOKU_CH_MIGRATION_TARGET'],'--actor','owned upgrade','--reason','retain fence']))['result']
        env['KANSOKU_CH_MIGRATION_SESSION']=report['id']
        def pg(sql): return run(['psql','-XAt','-v','ON_ERROR_STOP=1','-c',sql]).strip()
        pg("UPDATE kansoku.clickhouse_migration_sessions SET entry=7,pending_receipts='[\"exact-receipt\"]',outcome='failed'")
        before=json.loads(pg('SELECT row_to_json(s) FROM kansoku.clickhouse_migration_sessions s'))
        run([args.pg,'up'])
        after=json.loads(run([args.native,'maintenance','status','--json']))['result']
        assert all(after[key]==value for key,value in before.items())
        assert after['topology']=='direct' and after['replica_ids']==[] and after['cluster_name'] is None
        replicated={key:value for key,value in env.items() if key!='KANSOKU_CH_MIGRATION_SERVER_ID'}
        replicated.update(KANSOKU_CH_MIGRATION_CLUSTER='fixture',KANSOKU_CH_MIGRATION_REPLICA_IDS=env['KANSOKU_CH_MIGRATION_SERVER_ID'])
        run([args.native,'maintenance','status','--json'],False,replicated)
        assert pg('SELECT count(*) FROM kansoku.maintenance_fence WHERE active_migration_session IS NOT NULL')=='1'
    print('session upgrade: all legacy fields, fence, entry and exact receipts preserved; topology change refused')


if __name__=='__main__': main()
