"""Fresh owned fixture initialization through real binaries and persistent sessions.

The caller supplies process ownership and a real restart operation. This module
never accepts an ambient ClickHouse target or infers drain from process absence.
"""
from contextlib import contextmanager
import json
from pathlib import Path
import subprocess
import tempfile
import uuid


def initialize_owned(env, owner, native=None, pg_migrate=None):
    root = Path(env['KANSOKU_OWNED_CLICKHOUSE_ROOT'])
    def execute(args, settings, timeout=480):
        result = subprocess.run(args, env=settings, text=True, capture_output=True, timeout=timeout)
        with (root / 'native-migrations.private').open('a') as output:
            output.write(result.stdout + result.stderr)
        result.check_returncode()
        return result.stdout.strip()
    from test_support import binary
    native = native or env.get('KANSOKU_CH_MIGRATION_BINARY') or binary('kansoku-server:exe:kansoku-ch-migrate')
    pg_migrate = pg_migrate or env.get('KANSOKU_PG_MIGRATION_BINARY') or binary('kansoku-server:exe:kansoku-migrate')
    actual = execute(['clickhouse-client','--host','127.0.0.1','--port',env['CLICKHOUSE_TCP_PORT'],'--query',"SELECT value FROM system.server_settings WHERE name='path'"], env).rstrip('/')
    assert actual == str(root / 'data'), 'Refusing migrations on an unowned ClickHouse listener'
    if owner.get('failed'):
        raise RuntimeError('Failed owned initialization retains its coordinator/session; use explicit diagnosis and recovery')

    @contextmanager
    def coordinator():
        marker = env.get('KANSOKU_OWNED_POSTGRES_ROOT')
        if marker:
            actual = execute(['psql','-XAt','-v','ON_ERROR_STOP=1','-c','SHOW data_directory'],env)
            assert actual == str(Path(marker).resolve()), 'Refusing an unowned PostgreSQL coordinator'
            yield dict(env)
        else:
            from isolated_postgres import isolated_postgres
            # Every standalone scenario owns its coordinator. Never use ambient
            # PG_* variables merely because the caller happened to have them.
            with isolated_postgres(root / ('coordinator-' + uuid.uuid4().hex)) as pg:
                settings = dict(env)
                for key in list(settings):
                    if key.startswith('PG'):
                        settings.pop(key)
                settings.update({key:value for key,value in pg.items() if key.startswith('PG') or key == 'KANSOKU_OWNED_POSTGRES_ROOT'})
                execute([pg_migrate,'up'],settings)
                yield settings

    with coordinator() as settings:
        if 'identity' not in owner:
            identity = execute(['clickhouse-client','--host','127.0.0.1','--port',env['CLICKHOUSE_TCP_PORT'],'--query','SELECT toString(serverUUID())'],env)
            owner['identity'] = dict(KANSOKU_CH_MIGRATION_TARGET='kansoku/fixture-' + uuid.uuid4().hex,
                                     KANSOKU_CH_MIGRATION_ENDPOINT='http://127.0.0.1:' + env['CLICKHOUSE_HTTP_PORT'],
                                     KANSOKU_CH_MIGRATION_SERVER_ID=identity,
                                     KANSOKU_CH_MIGRATION_LEDGER_ID=str(uuid.uuid4()))
        settings.update(owner['identity'])
        audit = ['--expect-target',settings['KANSOKU_CH_MIGRATION_TARGET'],'--actor','owned Kansoku fixture','--reason','owned clients stopped and server restarted','--evidence',str(root / 'native-drain.private')]
        owner['failed'] = True
        begin = json.loads(execute([native,'maintenance','begin','--json',*audit],settings))['result']
        settings['KANSOKU_CH_MIGRATION_SESSION'] = begin['id']
        def entry(command):
            # Called only during setup, while the context owner admits no other
            # submitting clients. Restart is an actual operation on the owned
            # process and retained data root, never a fabricated CLI assertion.
            owner['restart']()
            status = json.loads(execute([native,'maintenance','status','--json'],settings))['result']
            (root / 'native-drain.private').write_text(json.dumps(dict(target=settings['KANSOKU_CH_MIGRATION_TARGET'],session=begin['id'],server=settings['KANSOKU_CH_MIGRATION_SERVER_ID'],ledger=settings['KANSOKU_CH_MIGRATION_LEDGER_ID'],predecessor=status['entry'],procedure='all owned submitting clients stopped; same data root server restarted')))
            return execute([native,'--predecessor',str(status['entry']),*command,'--json','--quiescent',*audit],settings)
        up = ['up']
        if not owner.get('initialized'):
            up += ['--initialize-ledger',settings['KANSOKU_CH_MIGRATION_LEDGER_ID']]
        entry(up)
        owner['initialized'] = True
        entry(['maintenance','finish'])
        owner['failed'] = False
        env.update(owner['identity'])
