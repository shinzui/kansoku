#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${KANSOKU_HURL_SECRETS_FILE:?Set a private Hurl secrets file; see README.md}"
base_url="${KANSOKU_HURL_BASE_URL:-http://127.0.0.1:8080}"
if [[ ! "$base_url" =~ ^http://127\.0\.0\.1:[0-9]+$ ]]; then
  echo >&2 'The safe runner accepts only an explicit IPv4 loopback URL.'
  exit 2
fi
hurlfmt --check health.hurl openapi.hurl schemas.hurl metrics.hurl ingest.hurl perimeter/perimeter.hurl perimeter/metrics-disabled.hurl
hurl --test --jobs 1 --variables-file vars.env --variable "base_url=$base_url" \
  --secrets-file "$KANSOKU_HURL_SECRETS_FILE" \
  health.hurl openapi.hurl schemas.hurl metrics.hurl
