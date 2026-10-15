# flake.module.nix — project-specific flake-parts customizations.
#
# UNMANAGED by seihou: never regenerated or overwritten by `seihou run` or by
# nix-haskell-flake migrations, so everything here survives template upgrades
# without conflict. flake.nix imports it automatically when present.
#
# This holds the project's Haskell package set (pinned overrides) and the
# kansoku-api/core/client/server package outputs. It was relocated here from the
# previously-managed nix/haskell.nix when nix-haskell-flake moved to the
# flake.module.nix extension model (nix.builtin-package = false), so the managed
# nix/haskell.nix no longer emits packages.default.
{ inputs, ... }:
{
  perSystem = { system, pkgs, config, ... }:
    let
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
            servantTelemetrySrc = pkgs.fetchFromGitHub {
              owner = "shinzui";
              repo = "hs-opentelemetry-instrumentation-servant";
              rev = "5e99a7857032484abc669076704dee4335e7d0ad";
              sha256 = "1djflpkg3xrm0hr9wn6cnsna6igqxf92wmrac8ghrcygkcbv1y3c";
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
            otelPackageWithOptions = name: subdir: options:
              dontCheck (doJailbreak (self.callCabal2nixWithOptions name (hsOpenTelemetrySrc + subdir) options { }));
            threadUtilsPackage = name: subdir:
              dontCheck (doJailbreak (self.callCabal2nix name (threadUtilsSrc + subdir) { }));
          in
          {
            ClickHaskell = dontCheck (doJailbreak (self.callCabal2nix "ClickHaskell" "${inputs.self}/vendor/ClickHaskell" { }));
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
            crypton-x509 = callHackageNoCheck "crypton-x509" "1.9.1" "1zh5w1isgzgl5vjb9skhrxidjzilx6fgarp3lgwbi264avh7lmpi";
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
            crypton-x509-validation = callHackageNoCheck "crypton-x509-validation" "1.9.1" "1c5c3jxqmskq6q8rd0ac7ljg0nimqixi776lsbyarwn20mb9zav0";
            hpke = callHackageNoCheck "hpke" "0.1.0" "07fqz8j2rlf6mq36s9v988q4i9wzhwjd1s9s0rqld79f3xs6zdpd";
            mlkem = callHackageNoCheck "mlkem" "0.2.2.0" "06k9iffnnbxkdfc204lghzsz3ibz700knarrb4y9lf98810d3934";
            tls = callHackageNoCheck "tls" "2.4.3" "0rgpgrmlips7r50s1rns8yz278qac0v90z76vpjh7pk4m65lsqhm";
            crypton-connection = callHackageNoCheck "crypton-connection" "0.4.6" "0q1h8npbka73nkgf7hp24w4yfd12bf91psvayrqi22js830cdrq7";
            http-client-tls = callHackageNoCheck "http-client-tls" "0.4.0" "1qgwh3zip36pbjn7c5pn1l6zv044d6l77mnariz66bdhwy9hrx1s";
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
            hs-opentelemetry-instrumentation-wai = callHackageNoCheck "hs-opentelemetry-instrumentation-wai" "1.0.0.0" "1b81alw81mrr8l0z82jcqrv20bxfp7ld818x38296cpmc69kvxc0";
            hs-opentelemetry-instrumentation-servant = pkgs.haskell.lib.compose.overrideCabal
              (old: {
                # The pinned library supports API 1.0; its unused example still
                # calls the pre-1.0 shutdown API. Keep that example out of builds.
                postPatch = (old.postPatch or "") + ''
                  echo '    buildable: False' >> hs-opentelemetry-instrumentation-servant.cabal
                '';
              })
              (dontCheck (self.callCabal2nix "hs-opentelemetry-instrumentation-servant" servantTelemetrySrc { }));
            hs-opentelemetry-exporter-in-memory = otelPackage "hs-opentelemetry-exporter-in-memory" "/exporters/in-memory";
            hs-opentelemetry-api-types = otelPackage "hs-opentelemetry-api-types" "/api-types";
            hs-opentelemetry-api = otelPackage "hs-opentelemetry-api" "/api";
            hs-opentelemetry-otlp = otelPackage "hs-opentelemetry-otlp" "/otlp";
            hs-opentelemetry-exporter-otlp = otelPackage "hs-opentelemetry-exporter-otlp" "/exporters/otlp";
            hs-opentelemetry-exporter-handle = otelPackage "hs-opentelemetry-exporter-handle" "/exporters/handle";
            hs-opentelemetry-propagator-b3 = otelPackage "hs-opentelemetry-propagator-b3" "/propagators/b3";
            hs-opentelemetry-propagator-datadog = otelPackage "hs-opentelemetry-propagator-datadog" "/propagators/datadog";
            hs-opentelemetry-propagator-jaeger = otelPackage "hs-opentelemetry-propagator-jaeger" "/propagators/jaeger";
            hs-opentelemetry-propagator-w3c = otelPackage "hs-opentelemetry-propagator-w3c" "/propagators/w3c";
            hs-opentelemetry-propagator-xray = otelPackage "hs-opentelemetry-propagator-xray" "/propagators/xray";
            hs-opentelemetry-sdk = otelPackageWithOptions "hs-opentelemetry-sdk" "/sdk" "-f-tls-metadata";
            hs-opentelemetry-semantic-conventions = otelPackage "hs-opentelemetry-semantic-conventions" "/semantic-conventions";

            hasql-migration =
              dontCheck (
                self.callCabal2nix
                  "hasql-migration"
                  hasqlMigrationSrc
                  { }
              );

            openapi-hs = callHackageNoCheck "openapi-hs" "5.0.0" "194lng0czgk0ma9463yydj9hnr2hpq99kxfx0p06xvwg36b11cin";
            servant-health = callHackageNoCheck "servant-health" "0.1.0.0" "1g24jnnijpap99vkmmqmkinlw18pg0hd23arrijgss430y63iv4x";
            servant-openapi-hs = callHackageNoCheck "servant-openapi-hs" "5.1.0" "19mvvlzfk7ffh5gbmqhpy587rjjd0xcgydbkcy1b48wxx061h8im";

            pg-migrate = callHackageNoCheck "pg-migrate" "1.1.0.0" "103y2bddn50pvrjnlhnfcqznlfihp68bpm72xg8s9xv2x8kv3s2b";
            pg-migrate-cli = callHackageNoCheck "pg-migrate-cli" "1.1.0.0" "1mc2scspfr1p872lxxl8pcpgf3gm2kp2xhjfwad9xv2wcnz1dj6w";
            pg-migrate-embed = callHackageNoCheck "pg-migrate-embed" "1.1.0.0" "01gxqrcqf9l6q2b6g6f1cnxymwkqlwn9cq34n5dj5whgh08gh335";
            pg-migrate-import-hasql-migration = callHackageNoCheck "pg-migrate-import-hasql-migration" "1.1.0.0" "0yih6qv870g1qri1sl1c99vdd86xvacpp40png5zz4mdzwsdxxsq";
            pg-migrate-test-support = callHackageNoCheck "pg-migrate-test-support" "1.1.0.0" "12f9kazn0kq34b7dacrwd1qkgbj3zmxhjr2xbr2q5lz7z80bs9cw";

            pgmq-core = callHackageNoCheck "pgmq-core" "0.4.0.1" "0cj8m5fdjk3sf4zsgj35ck4pjal7qlrmm5d0z7mm9ssc9kgmr6cn";
            pgmq-hasql = callHackageNoCheck "pgmq-hasql" "0.4.0.1" "0gkj8a56r10xkhqgwn07bpkg8x4gqb0v2px7anh3ghwjycc7kw66";
            pgmq-effectful = callHackageNoCheck "pgmq-effectful" "0.4.0.1" "1a3vkm5v52j0id1b8xf7fdpi9cv4s6jj7xg53dfccnj3x9rihxzz";
            pgmq-migration = callHackageNoCheck "pgmq-migration" "0.4.0.1" "01dq48chyx2fpqk740gz5z8f934az1ljfh5cb3319c44azqamr2y";
            data-sketches = callHackageNoCheck "data-sketches" "0.4.0.1" "0h6qkfrri6imlx8bdlpdy6927zwdr7ak4rv8lx1glifra7zgy6ab";
            data-sketches-core = callHackageNoCheck "data-sketches-core" "0.3.0.0" "1v9pn62qxphfhg3353jqqg6y8sh0k68m7d761c28pci2m2m398rg";
            prometheus-client = callHackageNoCheck "prometheus-client" "1.1.2" "1q8x24n7qy7s9sdiqvzzldgj52i36hzgq7wm4amzy3hv76p6vgfk";

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
    in
    {
      treefmt.settings.global.excludes = [ "vendor/**" ];
      packages = {
        default = kansokuServer;
        kansoku-api = kansokuApi;
        kansoku-client = kansokuClient;
        kansoku-core = kansokuCore;
        kansoku-server = kansokuServer;
      };
    };
}
