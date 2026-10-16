# Reproduce the external consumer gate

Run inside the repository's Nix development shell. Evidence and credentials stay under ignored
`.dev/acceptance/`, with owned PostgreSQL/ClickHouse/Grafana processes and random local ports.
The ordinary `just acceptance` always tests reader SQL/HTTP parity; use the required consumer
mode below for the release gate. Missing consumer paths are fatal in that mode.

The checked-in [consumer manifest](../examples/consumer-versions.json) records upstream
commits, release hashes and the exact backend executable hash. The harness refuses a different
GrowthBook commit, modified upstream adapter sources or a different plugin backend.

The accepted macOS arm64 consumer artifacts are Grafana OSS 13.2.4 (SHA256
`a910966466359212f1d875748a72a4638c7d3724448d0c369210b31d763b165d`) and official ClickHouse
plugin 4.22.1 (zip SHA256
`95efe0f32c2dc78ed29c63cc37c7fbe38cd7a25b9efd66be6b82497c3c0cc37f`). Obtain them from
[Grafana's download service](https://grafana.com/grafana/download/13.2.4) and
[the plugin registry](https://grafana.com/grafana/plugins/grafana-clickhouse-datasource/).
Extract each into a private directory; `KANSOKU_GRAFANA_HOME` contains `bin/grafana`, and
`KANSOKU_GRAFANA_PLUGINS` contains `grafana-clickhouse-datasource/plugin.json` and its signed
backend executable. Other operating-system artifacts need their own recorded hashes and proof.

Prepare unmodified GrowthBook v5.1.0 source at upstream commit
`7cbc85d1d113595757f6808b5c440657e4325b47`. Its canonical project reference is
`mori://growthbook/growthbook` (artifact-level URI pending for
`packages/back-end/src/integrations/ClickHouse.ts`). Use its frozen lockfile and packageManager
pin, pnpm 10.33.4, with Node 24 (the tested binary was 24.19.0):

```bash
mkdir -p .dev/acceptance/dependencies
git clone --depth 1 --branch v5.1.0 https://github.com/growthbook/growthbook.git \
  .dev/acceptance/dependencies/growthbook
export KANSOKU_GROWTHBOOK_SOURCE="$PWD/.dev/acceptance/dependencies/growthbook"
nix shell --inputs-from . nixpkgs#nodejs_24 -c sh -c '
  cd "$KANSOKU_GROWTHBOOK_SOURCE" &&
  CI=true pnpm dlx pnpm@10.33.4 install --frozen-lockfile \
    --filter growthbook-app --filter "back-end..." --ignore-scripts &&
  pnpm dlx pnpm@10.33.4 --filter @growthbook/growthbook run build &&
  pnpm dlx pnpm@10.33.4 --filter shared --filter stats-ts run build &&
  npm run install --prefix node_modules/.pnpm/kerberos@2.2.2/node_modules/kerberos'
```

The last command runs the locked native Kerberos dependency's upstream install hook; the
adapter imports upstream datasource services that load its SQL drivers. No Kerberos service,
MongoDB instance or statistics engine is exercised. The harness uses Node with upstream
`ts-node/register/transpile-only` and its tsconfig. Bun's different class-field initialization
would clear the adapter's constructor-initialized params and does not reproduce the shipped
upstream TypeScript target. It copies only the test runner into the private clone; upstream
source files remain unmodified.

Set the two Grafana paths, resolve the SDK checkout through Mori, build its distributions with
its own `nix develop -c just build`, then run:

```bash
export KANSOKU_GRAFANA_HOME='/absolute/private/path/to/grafana-13.2.4'
export KANSOKU_GRAFANA_PLUGINS='/absolute/private/path/to/grafana-plugins'
export KANSOKU_SDK_PROJECT='/absolute/path/resolved/from/mori'
KANSOKU_REQUIRE_SDK=1 KANSOKU_REQUIRE_CONSUMERS=1 just acceptance
```

For a focused reader/consumer run use `python3 scripts/reader_acceptance.py` with the same
consumer paths. The full gate executes packaged server/admin binaries; the focused default
uses source-built executables. Required SDK live, protocol and Chromium cases fail on missing
configuration, skipped tests, zero cases or a feature mismatch. See
[the consumption guide](consume-clickhouse.md) for the supported data contracts and boundaries.
