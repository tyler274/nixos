# Regression test for Coda CI in Firecracker:
#   nix build .#checks.x86_64-linux.coda-firecracker -L
# Runs the real coda-ci.nix in a throwaway VM with nested KVM and no
# internet: a stub stands in for the GitHub API, an XFS disk for the agents
# pool (both clone with reflinks), and an image built here for the job image.
{ pkgs, lib, ... }:
let
  # The controller's unit tests, run when the check builds.
  unitTests = pkgs.runCommand "coda-ci-unit-tests" {
    nativeBuildInputs = with pkgs; [ python3 coreutils e2fsprogs ];
  } ''
    cp ${../hosts/cyrene/coda_ci.py} coda_ci.py
    cp ${../hosts/cyrene/test_coda_ci.py} test_coda_ci.py
    python3 -m unittest -v test_coda_ci
    touch $out
  '';

  # Enough of a runner image for act's run steps, built offline.
  jobImage = pkgs.dockerTools.buildImage {
    name = "coda-test";
    tag = "latest";
    copyToRoot = pkgs.buildEnv {
      name = "coda-test-root";
      paths = with pkgs; [ bashInteractive coreutils curl gnugrep ];
      pathsToLink = [ "/bin" ];
    };
    extraCommands = ''
      mkdir -m 1777 tmp
      mkdir -p usr/bin
      ln -s /bin/env usr/bin/env    '';
    config.Env = [ "PATH=/bin" ];
  };

  workflow = pkgs.writeText "ci.yml" ''
    on: push
    jobs:
      ci:
        runs-on: blacksmith-4vcpu-ubuntu-2404
        steps:
          - run: echo CODA_TEST_JOB_RAN
          # Writes to the job's work disk, which must not reach the seed.
          - run: head -c 32M /dev/urandom > scratch.bin && sync
          - run: |
              curl --version >/dev/null
              for target in http://10.234.0.1:8080/ http://10.0.2.15:8080/ http://100.100.100.100/; do
                rc=0
                curl -s -m 3 -o /dev/null "$target" || rc=$?
                echo "CODA_PROBE $target $rc"
                # 28 is curl's timeout: the packets were dropped, not refused.
                [ "$rc" -eq 28 ]
              done
      fails:
        runs-on: ubuntu-latest
        steps:
          - run: exit 3
  '';

  githubStub = pkgs.writeText "github-stub.py" ''
    import http.server
    import json

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            with open("/var/log/github-stub.log", "a") as log:
                log.write(self.path + "\n")
            body = {"runners": []} if "/actions/runners" in self.path else {"workflow_runs": []}
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    http.server.HTTPServer(("127.0.0.1", 8099), Handler).serve_forever()
  '';
in
{
  name = "coda-firecracker";

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [ ../hosts/cyrene/coda-ci.nix ];

      virtualisation = {
        memorySize = 6144;
        cores = 4;
        qemu.options = [ "-cpu host" ];
        emptyDiskImages = [
          {
            size = 16384;
            driveConfig.deviceExtraOpts.serial = "ci";
          }
        ];
      };
      networking.nftables.enable = true;

      services.coda-ci = {
        enable = true;
        tokenFile = "/etc/coda-ci-test-token";
        apiUrl = "http://127.0.0.1:8099";
        # The stub listens on loopback, which Cyrene's controller may not use.
        controllerAddressDeny = [ "10.0.0.0/8" "100.64.0.0/10" ];
        marginMiB = 256;
        workDiskSize = "6G";
        guest = {
          microvm.mem = 2048;
          microvm.vcpu = 2;
          codaCiGuest = {
            image = "coda-test:latest";
            seedArchives = [ jobImage ];
            seedRunner = false;
          };
        };
      };
      environment.etc."coda-ci-test-token" = {
        text = "test-token";
        mode = "0400";
      };

      # Stands in for the agents pool: a reflink-capable disk at the CI path.
      systemd.services.agents-pool = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = with pkgs; [ xfsprogs util-linux ];
        script = ''
          disk=/dev/disk/by-id/virtio-ci
          blkid "$disk" || mkfs.xfs -q "$disk"
          mkdir -p /agents/coda/ci
          mountpoint -q /agents/coda/ci || mount "$disk" /agents/coda/ci
        '';
      };

      systemd.services.github-stub = {
        wantedBy = [ "multi-user.target" ];
        before = [ "coda-ci.service" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${githubStub}";
      };

      # A host service the guest must not reach.
      services.nginx = {
        enable = true;
        virtualHosts.default.listen = [ { addr = "0.0.0.0"; port = 8080; } ];
      };
      networking.firewall.allowedTCPPorts = [ 8080 ];

      users.users.alice.isNormalUser = true;
      environment.systemPackages = [ pkgs.git ];
    };

  testScript = ''
    def as_alice(cmd):
        return f"su - alice -c '{cmd}'"

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test -e ${unitTests}")

    with subtest("nested KVM and the CI spool"):
        machine.succeed("test -c /dev/kvm")
        machine.wait_for_unit("agents-pool.service")
        machine.wait_for_unit("coda-ci-spool.service")
        machine.succeed("test \"$(stat -c %a /agents/coda/ci/spool/requests)\" = 1733")

    with subtest("seed: a fresh work disk with the job image"):
        machine.succeed("systemctl start coda-ci-seed.service")
        machine.succeed("test -f /agents/coda/ci/seed/work.img")
        seed = machine.succeed("sha256sum < /agents/coda/ci/seed/work.img")
        machine.succeed("journalctl -u coda-ci-seed --no-pager | grep -q 'New seed'")

    with subtest("tap and egress rules exist"):
        machine.succeed("ip -br addr show fc-coda-ci | grep -q 10.234.0.1/30")
        machine.succeed("nft list table inet coda-ci")
        machine.succeed("nft list table ip nixos-nat | grep -q fc-coda-ci")

    with subtest("an act request runs offline, end to end"):
        machine.succeed(as_alice(
            "git init -q repo && mkdir -p repo/.github/workflows"
            " && cp ${workflow} repo/.github/workflows/ci.yml"
            " && git -C repo add -A"
            " && git -C repo -c user.name=t -c user.email=t@t commit -qm ci"
        ))
        out = machine.succeed(as_alice("cd repo && timeout 900 coda-ci act . ci") + " 2>&1")
        print(out)
        assert "CODA_TEST_JOB_RAN" in out, "job output missing"
        assert out.count("CODA_PROBE") >= 3, "egress probes missing"
        assert "CODA_JOB_EXIT=0" in out, "exit marker missing"

    with subtest("the GitHub queue was checked first"):
        requests = machine.succeed("cat /var/log/github-stub.log")
        assert "actions/runners?per_page=100" in requests, requests
        assert "actions/runs?status=queued" in requests, requests

    with subtest("nothing of the job is left, and the seed is unchanged"):
        machine.succeed("test -z \"$(ls -A /agents/coda/ci/jobs)\"")
        machine.fail("pgrep -x firecracker")
        assert machine.succeed("sha256sum < /agents/coda/ci/seed/work.img") == seed

    with subtest("a failing job reports failure"):
        machine.succeed(as_alice("cd repo && rc=0; timeout 900 coda-ci act . fails || rc=$?; test $rc -eq 1"))

    with subtest("an invalid request is rejected without a guest"):
        machine.succeed(
            "echo junk > /agents/coda/ci/spool/requests/abcdefabcdef.bundle",
            "echo 'bad name' > /agents/coda/ci/spool/requests/abcdefabcdef.job",
        )
        machine.wait_until_succeeds("test -e /agents/coda/ci/spool/results/abcdefabcdef/status", timeout=120)
        machine.succeed("grep -qx 125 /agents/coda/ci/spool/results/abcdefabcdef/status")
        machine.succeed("grep -q 'job name' /agents/coda/ci/spool/results/abcdefabcdef/log")
  '';
}
