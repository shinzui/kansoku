"""Use the real pinned Grafana server/plugin to import and execute the panel recipe."""
import base64
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.request
import uuid

from admin_acceptance import owned_process
from isolated_clickhouse import free_port

REPO = Path(__file__).resolve().parent.parent


def verify_grafana(env, root, home, plugins, connection, sql, expected):
    root = Path(root).resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    port, password = free_port(), uuid.uuid4().hex
    authorization = 'Basic ' + base64.b64encode(('admin:' + password).encode()).decode()
    base = f'http://127.0.0.1:{port}'
    settings = dict(env, GF_SERVER_HTTP_ADDR='127.0.0.1', GF_SERVER_HTTP_PORT=str(port),
        GF_SECURITY_ADMIN_PASSWORD=password, GF_PATHS_DATA=str(root / 'data'), GF_PATHS_LOGS=str(root / 'logs'),
        GF_PATHS_PLUGINS=str(Path(plugins).resolve()), GF_PATHS_PROVISIONING=str(root / 'provisioning'),
        GF_ANALYTICS_REPORTING_ENABLED='false', GF_ANALYTICS_CHECK_FOR_UPDATES='false',
        GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES='false', GF_PLUGINS_PREINSTALL_DISABLED='true')
    for directory in ('dashboards','datasources','plugins','alerting'):
        (root / 'provisioning' / directory).mkdir(parents=True,exist_ok=True)
    def api(path, body=None):
        request = urllib.request.Request(base + path, headers={'Authorization':authorization,'Content-Type':'application/json'},
            data=None if body is None else json.dumps(body).encode())
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            body=error.read().decode()
            (root / 'api-error.private').write_text(body)
            raise RuntimeError('Grafana API failed: ' + path) from None
    with (root / 'grafana.private').open('w') as log:
        with owned_process([str(Path(home).resolve() / 'bin/grafana'),'server','--homepath',str(Path(home).resolve())], settings, root, 'grafana',stdout=log,stderr=log) as process:
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                assert process.poll() is None, 'owned Grafana exited'
                try:
                    health = api('/api/health')
                    assert health['version'] == '13.2.4'
                    break
                except OSError:
                    time.sleep(.2)
            else:
                raise RuntimeError('owned Grafana readiness timed out')
            datasource = json.loads((REPO / 'docs/examples/grafana/datasource.json').read_text())
            datasource['jsonData'].update(port=connection['port'],username=connection['username'])
            datasource['secureJsonData']['password']=connection['password']
            api('/api/datasources',datasource)
            health = api('/api/datasources/uid/kansoku-reader/health')
            assert health['status'] == 'OK', 'real ClickHouse plugin health failed'
            dashboard = json.loads((REPO / 'docs/examples/grafana/dashboard.json').read_text())
            dashboard['dashboard']['panels'][0]['targets'][0]['rawSql']=sql
            api('/api/dashboards/db', dashboard)
            saved = api('/api/dashboards/uid/kansoku-daily-users')['dashboard']
            target = saved['panels'][0]['targets'][0]
            result = api('/api/ds/query',dict(queries=[dict(target,datasource=dict(type='grafana-clickhouse-datasource',uid='kansoku-reader'),intervalMs=1000,maxDataPoints=1000)], **{'from':'0','to':str(int(time.time()*1000))}))
            (root / 'query.private').write_text(json.dumps(result))
            answer = result['results']['A']
            assert not answer.get('error'), 'real Grafana panel query failed'
            frames = answer['frames']
            assert len(frames)==1
            names = [field['name'] for field in frames[0]['schema']['fields']]
            values = frames[0]['data']['values']
            assert names==['day','value'] and values[1]==[row['value'] for row in expected], 'Grafana panel answer differs from reader SQL'
            print('Grafana 13.2.4 / ClickHouse plugin 4.22.1: real datasource health, dashboard import/readback and panel query passed (3 cases, 0 skipped).',flush=True)
