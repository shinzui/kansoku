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
            optparse-applicative = callHackageNoCheck "optparse-applicative" "0.19.0.0" "0cs8fqipakad38lvm75nz98hmvf881mgjhnc7icblxfzh92ay6kn";
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

            openapi-hs = callHackageNoCheck "openapi-hs" "4.1.0" "0pn1ml34hphjx8xfzhmdz3a53xicfl6694i7zvi9zi8pw1pb60s9";
            servant-openapi-hs = callHackageNoCheck "servant-openapi-hs" "4.1.0" "1pm1563js3hl9xxv5pzkbclpx47dkjvyfcynv6alb69f5zhmdkl0";

            pg-migrate = callHackageNoCheck "pg-migrate" "1.1.0.0" "103y2bddn50pvrjnlhnfcqznlfihp68bpm72xg8s9xv2x8kv3s2b";
            pg-migrate-cli = callHackageNoCheck "pg-migrate-cli" "1.1.0.0" "1mc2scspfr1p872lxxl8pcpgf3gm2kp2xhjfwad9xv2wcnz1dj6w";
            pg-migrate-embed = callHackageNoCheck "pg-migrate-embed" "1.1.0.0" "01gxqrcqf9l6q2b6g6f1cnxymwkqlwn9cq34n5dj5whgh08gh335";
            pg-migrate-import-hasql-migration = callHackageNoCheck "pg-migrate-import-hasql-migration" "1.1.0.0" "0yih6qv870g1qri1sl1c99vdd86xvacpp40png5zz4mdzwsdxxsq";
            pg-migrate-test-support = callHackageNoCheck "pg-migrate-test-support" "1.1.0.0" "12f9kazn0kq34b7dacrwd1qkgbj3zmxhjr2xbr2q5lz7z80bs9cw";

            pgmq-core = callHackageNoCheck "pgmq-core" "0.4.0.1" "0cj8m5fdjk3sf4zsgj35ck4pjal7qlrmm5d0z7mm9ssc9kgmr6cn";
            pgmq-hasql = callHackageNoCheck "pgmq-hasql" "0.4.0.1" "0gkj8a56r10xkhqgwn07bpkg8x4gqb0v2px7anh3ghwjycc7kw66";
            pgmq-effectful = callHackageNoCheck "pgmq-effectful" "0.4.0.1" "1a3vkm5v52j0id1b8xf7fdpi9cv4s6jj7xg53dfccnj3x9rihxzz";
            pgmq-migration = callHackageNoCheck "pgmq-migration" "0.4.0.1" "01dq48chyx2fpqk740gz5z8f934az1ljfh5cb3319c44azqamr2y";

            shibuya-core = callHackageNoCheck "shibuya-core" "0.8.0.1" "1ks1pc9yz7xg18c3p719ad5608409s1gjd0qqaj0fp2qc2yjbc3s";
            shibuya-pgmq-adapter = callHackageNoCheck "shibuya-pgmq-adapter" "0.12.0.0" "15zgpvfdx4ab75ap95zmkyhlsqk3jj017vcd8j2p18jjwbpffh9f";
          };
      };

      kansokuApi = haskellPackages.callCabal2nix "kansoku-api" "${inputs.self}/kansoku-api" { };
      kansokuCore = pkgs.haskell.lib.dontCheck (haskellPackages.callCabal2nix "kansoku-core" "${inputs.self}/kansoku-core" {
        kansoku-api = kansokuApi;
      });
      kansokuClient = haskellPackages.callCabal2nix "kansoku-client" "${inputs.self}/kansoku-client" {
        kansoku-api = kansokuApi;
      };
      kansokuServer = haskellPackages.callCabal2nix "kansoku-server" "${inputs.self}/kansoku-server" {
        kansoku-api = kansokuApi;
        kansoku-core = kansokuCore;
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
      packages = {
        default = kansokuServer;
        kansoku-api = kansokuApi;
        kansoku-client = kansokuClient;
        kansoku-core = kansokuCore;
        kansoku-server = kansokuServer;
      };

      devShells.default = mkProjectShell "ghc9124";
      devShells."ghc9124" = mkProjectShell "ghc9124";
    };
}
