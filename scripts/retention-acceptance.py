#!/usr/bin/env python3
"""Calendar retention producer, HTTP and typed-client proof on owned stores."""
from pathlib import Path
from activity_acceptance import verify_calendar_retention
from cohorts_acceptance import main


def verify(base, write_key, token, other_token, **kwargs):
    verify_calendar_retention(base, write_key, token, typed_client=True)


if __name__ == '__main__':
    main(verify=verify, server_environment={
        'KANSOKU_INGEST_GEOIP_DB': str(Path('kansoku-core/test/fixtures/geoip/GeoIP2-Country-Test.mmdb').resolve()),
        'KANSOKU_INGEST_TRUSTED_PROXY_CIDRS': '127.0.0.1/32',
    })
