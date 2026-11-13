#!/usr/bin/env python3
"""Derive release expectations from the real immutable plan on an owned server."""
import argparse
import json
import os
from pathlib import Path
import tempfile

from clickhouse_migrations_acceptance import owned
from test_support import binary


def derive(root,native,pg_migrate,admin):
    with owned(root,native,native,pg_migrate,admin,backups=False) as h:
        h.begin()
        h.up(first=True)
        context=json.loads(h.run([native,'maintenance','recovery-context','--json']).stdout)['result']
        tables=[json.loads(line) for line in h.sql("SELECT name,engine,engine_full,create_table_query,partition_key,sorting_key,primary_key,sampling_key FROM system.tables WHERE database='analytics' ORDER BY name FORMAT JSONEachRow").splitlines()]
        columns=[json.loads(line) for line in h.sql("SELECT table,name,type,position,default_kind,default_expression,compression_codec FROM system.columns WHERE database='analytics' ORDER BY table,position FORMAT JSONEachRow").splitlines()]
        qualified=next(entry for entry in json.loads(Path('db/clickhouse/qualification/matrix.json').read_text())['entries'] if entry['id']=='lts-native')
        version=h.sql('SELECT version()').strip()
        assert version==qualified['version']
        return dict(schemaVersion=1,planSha256=context['planSha256'],serverVersion=version,serverArtifact={key:qualified[key] for key in ('id','version','platform','sha256','url')},applicationDatabase='analytics',databaseEngine=h.sql("SELECT engine FROM system.databases WHERE name='analytics'").strip(),tables=tables,columns=columns)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',default='kansoku-server/migrations/clickhouse/schema-expectation.json')
    args=parser.parse_args()
    os.umask(0o077)
    root=Path(tempfile.mkdtemp(prefix='schema-expectation-',dir='.dev/acceptance')).resolve()
    result=derive(root,binary('kansoku-server:exe:kansoku-ch-migrate'),binary('kansoku-server:exe:kansoku-migrate'),binary('kansoku-server:exe:kansoku-admin'))
    Path(args.output).write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print(str(len(result['tables']))+' objects / '+str(len(result['columns']))+' columns derived from compiled plan '+result['planSha256'],flush=True)
