# Haskell project wiring: dev shells (via the haskell-nix-dev base flake) and the
# project package (via callCabal2nix). seihou-managed — to add project-specific
# dev tools without editing this file, set `haskellProject.extraDevPackages` from
# ./flake.module.nix (see flake.module.nix.example).
{ inputs, lib, flake-parts-lib, ... }:
{
  options.perSystem = flake-parts-lib.mkPerSystemOption ({ ... }: {
    options.haskellProject.extraDevPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.ghciwatch pkgs.haskellPackages.hpack ]";
      description = ''
        Extra packages to add to the dev shell. Set this from ./flake.module.nix
        to add project-specific tooling without editing the generated
        ./nix/haskell.nix.
      '';
    };
  });

  config.perSystem = { system, pkgs, config, ... }:
    let
      hsdev = inputs.haskell-nix-dev.lib.${system};
      haskellPackages = pkgs.haskell.packages."ghc9124";

      baseDevPackages = [
        pkgs.zlib
        pkgs.just
        pkgs.pkg-config
        pkgs.postgresql
        pkgs.jq
        pkgs.clickhouse
        pkgs.process-compose
      ];

      shellHook = ''
        ${config.pre-commit.installationScript}

        export PGHOST="$PWD/db"
        export PGDATA="$PGHOST/db"
        export PGLOG=$PGHOST/postgres.log
        export PGDATABASE=kansoku
        export PG_CONNECTION_STRING=postgresql://$(jq -rn --arg x $PGHOST '$x|@uri')/$PGDATABASE

        mkdir -p $PGHOST
        mkdir -p .dev

        if [ ! -d $PGDATA ]; then
          initdb --auth=trust --no-locale --encoding=UTF8
        fi

        # Local, rootless ClickHouse. The server (started by process-compose, or
        # manually with `clickhouse-server --path=$CLICKHOUSE_HOME/ …`) keeps all
        # of its state under CLICKHOUSE_HOME and uses clickhouse's embedded
        # default config. Override the ports here (or in an unmanaged .envrc/
        # flake.module.nix) if two projects need to run side by side.
        export CLICKHOUSE_HOME="$PWD/clickhouse"
        export CLICKHOUSE_TCP_PORT=9000
        export CLICKHOUSE_HTTP_PORT=8123

        mkdir -p $CLICKHOUSE_HOME
        mkdir -p .dev
      '';

      mkProjectShell = ghc: hsdev.mkDevShell {
        inherit ghc;
        extraNativeBuildInputs = baseDevPackages ++ config.haskellProject.extraDevPackages;
        withHls = true;
        inherit shellHook;
      };
    in
    {
      packages.default = haskellPackages.callCabal2nix "kansoku" inputs.self { };

      devShells.default = mkProjectShell "ghc9124";
      devShells."ghc9124" = mkProjectShell "ghc9124";
    };
}
