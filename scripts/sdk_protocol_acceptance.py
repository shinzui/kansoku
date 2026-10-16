"""A dedicated shared credential bucket proves real SDK retries and beacon limits."""
import json
from pathlib import Path
import subprocess
import time
import urllib.request
import uuid
from admin_acceptance import owned_process
from isolated_clickhouse import free_port
from test_support import execute


def verify_sdk_protocol(server,admin,env,root,sdk,tokens=None):
    root=Path(root)
    root.mkdir(mode=0o700,parents=True,exist_ok=True)
    output=subprocess.check_output([admin,'issue-key','--kind','write','--account','protocol-'+uuid.uuid4().hex],env=env,text=True)
    key=output.strip().splitlines()[-2]
    if tokens is not None:tokens.append(key)
    port=free_port()
    base=f'http://127.0.0.1:{port}'
    settings=dict(env,KANSOKU_SERVER_PORT=str(port),KANSOKU_QUEUE_NAME='protocol_'+uuid.uuid4().hex,
        KANSOKU_INGEST_MAX_BATCH_LENGTH='2',KANSOKU_INGEST_RATE_PER_SEC='1',KANSOKU_INGEST_RATE_BURST='2',
        KANSOKU_LIVE_BASE_URL=base,KANSOKU_LIVE_WRITE_KEY=key)
    with (root/'server.private').open('w') as log:
        with owned_process([server],settings,root,'sdk-protocol',stdout=log,stderr=log) as process:
            deadline=time.monotonic()+30
            while time.monotonic()<deadline:
                assert process.poll() is None
                try:
                    urllib.request.urlopen(base+'/health/ready',timeout=2).close()
                    break
                except OSError:time.sleep(.1)
            else:raise RuntimeError('owned SDK protocol server readiness timed out')
            result=execute(['bun','run','scripts/protocol-live.ts'],env=settings,cwd=sdk,timeout=45)
            (root/'consumer.private').write_text(result.stdout+result.stderr)
            result.check_returncode()
            assert json.loads(result.stdout.strip().splitlines()[-1])==dict(cases=3,skipped=0,result='passed')
    print('Required SDK protocol: real beacon 413/shared 429 and Retry-After retry (3 cases, 0 skipped), passed.',flush=True)
