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
      haskellPackages = pkgs.haskell.packages."ghc9124".override {
        overrides = self: super:
          let
            doJailbreak = pkgs.haskell.lib.doJailbreak;
            dontCheck = pkgs.haskell.lib.dontCheck;
            disableCabalFlag = pkgs.haskell.lib.compose.disableCabalFlag;
            callHackageNoCheck = pkg: ver: sha256:
              dontCheck (doJailbreak (self.callHackageDirect
                {
                  inherit pkg ver sha256;
                }
                { }));
            hasqlMigrationSrc = pkgs.fetchFromGitHub {
              owner = "shinzui";
              repo = "hasql-migration";
              rev = "4aaff6c0919d1fe8e1c248c3ce4ce05775c59c8c";
              sha256 = "13nsr8jzmvqr3ka5liic1sgm8brszzyfvxd0djm3ccc4smphbh68";
            };
            openapiHsSrc = pkgs.fetchFromGitHub {
              owner = "shinzui";
              repo = "openapi-hs";
              rev = "e570ad70cf9bc1a2b229d33af0455dff28650010";
              sha256 = "1s638lalywshrsgb3d6k5czrgb9fwmg3w19qvhmjk8qz2lsh5bj8";
            };
            servantOpenapiHsSrc = pkgs.fetchFromGitHub {
              owner = "shinzui";
              repo = "servant-openapi-hs";
              rev = "aa4df1f831e02c6370c9eb4129b158f8268f3ae0";
              sha256 = "1jsjbn2b01azyhl88x0z15mvdz9gjjwmyplhpqmd1c9jr97d1n8a";
            };
            pgmqHsSrc = pkgs.fetchFromGitHub {
              owner = "shinzui";
              repo = "pgmq-hs";
              rev = "973c1076f469448818de5d2044a483296be2c02e";
              sha256 = "1242gyf3yx2wr1fycsla5mbw4drdz1l6wp8q7hkcspx92yvr6vm7";
            };
            shibuyaSrc = pkgs.fetchFromGitHub {
              owner = "shinzui";
              repo = "shibuya";
              rev = "bdfccae3aee883c232457c788c495d28a73ec6e3";
              sha256 = "0hsxd4j6bizzzp9mc3rrsl8hk5zdjypcg31ayr74m25mj6jvl6ks";
            };
            shibuyaPgmqAdapterSrc = pkgs.fetchFromGitHub {
              owner = "shinzui";
              repo = "shibuya-pgmq-adapter";
              rev = "71a7b82223449d84c395b64e480c9cfe4ff274f1";
              sha256 = "095vl9rjdhrpsq5vwcfxf4627la44189gqvmbrda2idqlqj5p5pz";
            };
            hsOpenTelemetrySrc = pkgs.fetchFromGitHub {
              owner = "iand675";
              repo = "hs-opentelemetry";
              rev = "46a42cdf80405fdb36fbb48a309254b2332617b4";
              hash = "sha256-4wMAK3WtoSlyrP0IFWFNME///HIXdMZcPfH6ZKpkVfw=";
            };
            threadUtilsSrc = pkgs.fetchFromGitHub {
              owner = "iand675";
              repo = "thread-utils";
              rev = "519ff4613a5b5ee3904be7daefb94bf99ada5ee5";
              hash = "sha256-nlKK794LNHGjXKB1lhCkFJuCEyH+aiGOg6ljV4P1Ijw=";
            };
            otelPackage = name: subdir:
              dontCheck (doJailbreak (self.callCabal2nix name (hsOpenTelemetrySrc + subdir) { }));
            threadUtilsPackage = name: subdir:
              dontCheck (doJailbreak (self.callCabal2nix name (threadUtilsSrc + subdir) { }));
          in
          {
            unicode-data = dontCheck super.unicode-data;
            warp = disableCabalFlag "x509" super.warp;
            hasql = dontCheck (doJailbreak (self.callHackageDirect
              {
                pkg = "hasql";
                ver = "1.10.2.4";
                sha256 = "sha256-mUQETQuvWW+AenCprqD3IPyfdpMIFO2Dzke3wz/ae24=";
              }
              { }));
            hasql-pool = dontCheck (doJailbreak (self.callHackageDirect
              {
                pkg = "hasql-pool";
                ver = "1.4.1";
                sha256 = "sha256-ypgn5F9WhFozOGRvT55xGTRFwviDdTJfn/dJSWUzviI=";
              }
              { }));
            hasql-transaction = dontCheck (doJailbreak (self.callHackageDirect
              {
                pkg = "hasql-transaction";
                ver = "1.2.2";
                sha256 = "sha256-o53h6ly2Kukhw9dcyAOvywzwlZDdgb+b/jqbw72lLHg=";
              }
              { }));
            postgresql-binary = dontCheck (doJailbreak (self.callHackageDirect
              {
                pkg = "postgresql-binary";
                ver = "0.15.0.1";
                sha256 = "sha256-q5t2OgiDxyt8WU+zHVxpyVhFF9PtDu2BlQRfuPpBkgk=";
              }
              { }));
            crypton = dontCheck (self.callHackageDirect
              {
                pkg = "crypton";
                ver = "1.1.2";
                sha256 = "0lydqmcil3h1bbjbn90qvl6ldz4ar9vks7wr9s7588pj70jljicn";
              }
              { });
            ram = dontCheck (self.callHackageDirect
              {
                pkg = "ram";
                ver = "0.22.0";
                sha256 = "1mwg8gha1y2hvk7yf2kd9411ibqba0r9ach1ypg6yk5mxqrfgcv7";
              }
              { });
            crypton-x509 = dontCheck (self.callHackageDirect
              {
                pkg = "crypton-x509";
                ver = "1.9.0";
                sha256 = "179mrn79kyk6srf6k38q5vls894d0bmcvg56n3j45vrqd0r9kwyr";
              }
              { });
            crypton-x509-store = dontCheck (self.callHackageDirect
              {
                pkg = "crypton-x509-store";
                ver = "1.9.0";
                sha256 = "0m0awxdc91lkjrzhdkrpm538hsv0546zr8b4v1wd71wq6c8041qr";
              }
              { });
            crypton-x509-system = dontCheck (self.callHackageDirect
              {
                pkg = "crypton-x509-system";
                ver = "1.9.0";
                sha256 = "1yw0h3k3dxnb35ma5x7qb2hpxf1rvag8c2hjqx2qbidmjfzffykb";
              }
              { });
            crypton-x509-validation = dontCheck (self.callHackageDirect
              {
                pkg = "crypton-x509-validation";
                ver = "1.9.0";
                sha256 = "07xmh65ml9r51ijz0sv6rk3s46flmmafcka5ik63pqxhn2za20w0";
              }
              { });
            tls = dontCheck (doJailbreak (self.callHackageDirect
              {
                pkg = "tls";
                ver = "2.3.1";
                sha256 = "1a7k5fjgh39hy73napwn331wcgfi8q4b3z14qvl7ix19pd2gi8zs";
              }
              { }));
            generic-lens-core = callHackageNoCheck "generic-lens-core" "2.3.0.0" "05im3y27lhjjy6hi0i85rlqsan510fmp63lqfwg18cnlzn0yvf81";
            generic-lens = callHackageNoCheck "generic-lens" "2.3.0.0" "06q0ghaj90hqp0chb3z5qzr3cx8ypanjk24d4wnb1b7b8s13rhsp";
            streamly-core =
              dontCheck (doJailbreak (self.callCabal2nix "streamly-core"
                (builtins.fetchTarball {
                  url = "https://hackage.haskell.org/package/streamly-core-0.3.0/streamly-core-0.3.0.tar.gz";
                  sha256 = "sha256-IOrPT45LfuzU1zs4YXAsrVXYAauIKUwElgB8O7ZMk6Q=";
                })
                { }));
            streamly =
              dontCheck (doJailbreak (self.callCabal2nix "streamly"
                (builtins.fetchTarball {
                  url = "https://hackage.haskell.org/package/streamly-0.11.0/streamly-0.11.0.tar.gz";
                  sha256 = "sha256-JMZAwJHqmDxN/CCDFhfuv77xmAx1JVhvYFDxMKyQoGk=";
                })
                { }));
            thread-utils-finalizers = threadUtilsPackage "thread-utils-finalizers" "/thread-utils-finalizers";
            thread-utils-context = threadUtilsPackage "thread-utils-context" "/thread-utils-context";
            hs-opentelemetry-api-types = otelPackage "hs-opentelemetry-api-types" "/api-types";
            hs-opentelemetry-api = otelPackage "hs-opentelemetry-api" "/api";
            hs-opentelemetry-propagator-w3c = otelPackage "hs-opentelemetry-propagator-w3c" "/propagators/w3c";
            hs-opentelemetry-semantic-conventions = otelPackage "hs-opentelemetry-semantic-conventions" "/semantic-conventions";

            hasql-migration =
              dontCheck (
                self.callCabal2nix
                  "hasql-migration"
                  hasqlMigrationSrc
                  { }
              );

            openapi-hs =
              dontCheck (
                doJailbreak (
                  self.callCabal2nix
                    "openapi-hs"
                    openapiHsSrc
                    { }
                )
              );
            servant-openapi-hs =
              dontCheck (
                doJailbreak (
                  self.callCabal2nix
                    "servant-openapi-hs"
                    servantOpenapiHsSrc
                    { }
                )
              );

            pgmq-core =
              dontCheck (
                self.callCabal2nix
                  "pgmq-core"
                  "${pgmqHsSrc}/pgmq-core"
                  { }
              );
            pgmq-hasql =
              dontCheck (
                self.callCabal2nix
                  "pgmq-hasql"
                  "${pgmqHsSrc}/pgmq-hasql"
                  { }
              );
            pgmq-effectful =
              dontCheck (
                self.callCabal2nix
                  "pgmq-effectful"
                  "${pgmqHsSrc}/pgmq-effectful"
                  { }
              );
            pgmq-migration =
              dontCheck (
                pkgs.haskell.lib.overrideCabal
                  (self.callCabal2nix
                    "pgmq-migration"
                    "${pgmqHsSrc}/pgmq-migration"
                    { })
                  (old: {
                    postPatch = (old.postPatch or "") + ''
                      rm -f vendor
                      ln -s ${pgmqHsSrc}/vendor vendor
                    '';
                  })
              );

            shibuya-core =
              dontCheck (
                self.callCabal2nix
                  "shibuya-core"
                  "${shibuyaSrc}/shibuya-core"
                  { }
              );
            shibuya-pgmq-adapter =
              dontCheck (
                self.callCabal2nix
                  "shibuya-pgmq-adapter"
                  "${shibuyaPgmqAdapterSrc}/shibuya-pgmq-adapter"
                  { }
              );
          };
      };

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
      packages.default = haskellPackages.callCabal2nix "kansoku-server" inputs.self { };

      devShells.default = mkProjectShell "ghc9124";
      devShells."ghc9124" = mkProjectShell "ghc9124";
    };
}
