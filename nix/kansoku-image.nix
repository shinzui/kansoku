# Reuse the image layout qualified by mori://tan/tan-ng-labs. No Labs input or deployment changes.
{ pkgs, kansokuServer, sourceRevision }:
let
  imageRepository = "gcr.io/tan-ng/kansoku";
  imageTag = "${builtins.substring 0 12 sourceRevision}-p1";
  entrypoint = pkgs.writeTextFile {
    name = "kansoku-entrypoint";
    destination = "/entrypoint.sh";
    executable = true;
    text = builtins.readFile ../packaging/entrypoint.sh;
  };
  imageArgs = {
    name = imageRepository;
    tag = imageTag;
    contents = [ kansokuServer pkgs.busybox pkgs.cacert entrypoint ];
    compressor = "none";
    extraCommands = ''
      mkdir -m 1777 tmp
    '';
    config = {
      Entrypoint = [ "/entrypoint.sh" ];
      Cmd = [ "kansoku-server" ];
      ExposedPorts."8080/tcp" = { };
      Env = [ "PATH=/bin" "LANG=C.UTF-8" "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
      Labels = {
        "org.opencontainers.image.source" = "https://github.com/shinzui/kansoku";
        "org.opencontainers.image.revision" = sourceRevision;
        "tan.dev.packaging-revision" = "p1";
      };
    };
  };
  image = pkgs.dockerTools.buildLayeredImage (imageArgs // { passthru = { inherit imageArgs; }; });
in
{
  inherit image imageArgs;
  smoke = pkgs.testers.runNixOSTest {
    name = "kansoku-image-smoke";
    nodes.machine = { ... }: {
      virtualisation.docker.enable = true;
      virtualisation.diskSize = 8192;
      virtualisation.memorySize = 2048;
    };
    testScript = ''
      import json
      image = "${imageRepository}:${imageTag}"
      supplied = {
          "DATABASE_URL": "postgresql://image-proof@pg/kansoku",
          "CLICKHOUSE_HOST": "owned-clickhouse",
          "CLICKHOUSE_USER": "kansoku_runtime",
          "CLICKHOUSE_PASSWORD": "image-proof-only",
          "KANSOKU_CLICKHOUSE_SECURE": "true",
          "CLICKHOUSE_TCP_PORT": "9440",
      }
      explicit = {
          "PG_CONNECTION_STRING": "postgresql://explicit@pg/explicit",
          "KANSOKU_CLICKHOUSE_HOST": "explicit-host",
          "KANSOKU_CLICKHOUSE_USER": "explicit-user",
          "KANSOKU_CLICKHOUSE_PASSWORD": "explicit-proof-only",
      }
      def run(env, *args):
          flags = " ".join(f"-e {key}='{value}'" for key, value in env.items())
          return f"docker run --rm --network none {flags} {image} {' '.join(args)}"
      def environment(env):
          return dict(row.split("=", 1) for row in machine.succeed(run(env, "env")).splitlines() if "=" in row)
      machine.wait_for_unit("docker.service")
      machine.succeed("docker load -i ${image}")
      image_id = machine.succeed(f"docker image inspect --format '{{{{.Id}}}}' {image}").strip()
      print("Kansoku image configuration: " + image_id)
      plan = json.loads(machine.succeed(run(supplied, "kansoku-ch-migrate", "plan", "--json")))
      assert plan["status"] == "ok" and len(plan["result"]["schedule"]) == 25
      mapped = environment(supplied)
      for key, origin in {
          "PG_CONNECTION_STRING": "DATABASE_URL",
          "KANSOKU_CLICKHOUSE_HOST": "CLICKHOUSE_HOST",
          "KANSOKU_CLICKHOUSE_USER": "CLICKHOUSE_USER",
          "KANSOKU_CLICKHOUSE_PASSWORD": "CLICKHOUSE_PASSWORD",
      }.items():
          assert mapped[key] == supplied[origin]
      assert mapped["KANSOKU_CLICKHOUSE_SECURE"] == "true"
      assert mapped["CLICKHOUSE_TCP_PORT"] == "9440"
      override = environment({**supplied, **explicit})
      for key, value in explicit.items():
          assert override[key] == value
      machine.fail(run({key: value for key, value in supplied.items() if key != "DATABASE_URL"}, "env"))
      for executable in ["kansoku-server", "kansoku-migrate", "kansoku-ch-migrate", "kansoku-admin"]:
          machine.succeed(run(supplied, "sh", "-c", f"'command -v {executable}'"))
      machine.succeed(run(supplied, "sh", "-c", "'test -s \"$SSL_CERT_FILE\"'"))
    '';
  };
}
