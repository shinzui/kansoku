{ pkgs, system }:
let
  matrix = builtins.fromJSON (builtins.readFile ../db/clickhouse/qualification/matrix.json);
  candidate = builtins.head matrix.entries;
  binary = pkgs.fetchurl {
    inherit (candidate) url sha256;
  };
in
if system == "aarch64-darwin" then
  pkgs.runCommand "clickhouse-qualified-${candidate.version}" { } ''
    # The official macOS download expands itself beside its executable on first
    # launch. Expand the digest-verified artifact in the writable build directory
    # before installing it into the immutable output.
    cp ${binary} clickhouse
    chmod +x clickhouse
    ./clickhouse server --version
    mkdir -p "$out/bin"
    cp clickhouse "$out/bin/clickhouse"
    for command in server client local; do
      cat > "$out/bin/clickhouse-$command" <<EOF
    #!${pkgs.runtimeShell}
    exec $out/bin/clickhouse $command "\$@"
    EOF
      chmod +x "$out/bin/clickhouse-$command"
    done
  ''
else
  pkgs.writeShellScriptBin "clickhouse-server" ''
    echo 'ClickHouse migration execution is unqualified on ${system}; see db/clickhouse/qualification/matrix.json.' >&2
    exit 1
  ''
