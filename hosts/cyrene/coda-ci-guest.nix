# The disposable Firecracker guest that runs one Coda CI job.
#
# The controller (coda_ci.py) gives each boot two raw ext4 disks and nothing
# else from the host:
#   work.img    writable; a reflink clone of the seed with Docker's images
#   inputs.img  read-only; `mode` plus the job's payload:
#                 github  jit                    (a JIT runner config)
#                 act     repo.bundle, job       (a bundle with refs/coda-ci/head, a job id)
#                 seed    nothing                (pull the pinned images)
# The job's output leaves only over the serial console. Its last line is
# CODA_JOB_EXIT=<status>, and then the guest reboots, which ends Firecracker.
{ config, lib, pkgs, ... }:
let
  cfg = config.codaCiGuest;
  runnerVersion = "2.338.2";
  runnerSha256 = "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40";
  runnerTarball = "/work/cache/actions-runner-${runnerVersion}.tar.gz";
  # Labels the coda-rust workflows run on; act maps all of them to the image.
  labels = [
    "ubuntu-latest"
    "blacksmith-2vcpu-ubuntu-2404"
    "blacksmith-4vcpu-ubuntu-2404"
    "blacksmith-8vcpu-ubuntu-2404"
    "cyrene-coda"
  ];

  job = pkgs.writeShellApplication {
    name = "coda-job";
    runtimeInputs = with pkgs; [ act coreutils curl docker git gnutar gzip ];
    text = ''
      mode=$(cat /inputs/mode)
      install -d /work/cache /work/act /work/runner
      case "$mode" in
        seed)
          ${if cfg.seedArchives == [ ] then ''
            docker pull ${lib.escapeShellArg cfg.image}
          '' else lib.concatMapStrings (archive: ''
            docker load -i ${archive}
          '') cfg.seedArchives}
          ${lib.optionalString cfg.seedRunner ''
            curl -fsSL -o ${runnerTarball}.part \
              https://github.com/actions/runner/releases/download/v${runnerVersion}/actions-runner-linux-x64-${runnerVersion}.tar.gz
            echo "${runnerSha256}  ${runnerTarball}.part" | sha256sum -c -
            mv ${runnerTarball}.part ${runnerTarball}
          ''}
          docker image inspect ${lib.escapeShellArg cfg.image} >/dev/null
          ;;
        github)
          if [ ! -e ${runnerTarball} ]; then
            curl -fsSL -o ${runnerTarball} \
              https://github.com/actions/runner/releases/download/v${runnerVersion}/actions-runner-linux-x64-${runnerVersion}.tar.gz
          fi
          echo "${runnerSha256}  ${runnerTarball}" | sha256sum -c -
          tar -xzf ${runnerTarball} -C /work/runner
          # The runner sees the same /work/runner path as the guest's Docker,
          # so job containers it starts bind real paths.
          docker run --rm --network host \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v /work/runner:/work/runner -w /work/runner \
            -v /inputs/jit:/run/coda/jit:ro \
            -e RUNNER_ALLOW_RUNASROOT=1 \
            --entrypoint /bin/bash \
            ${lib.escapeShellArg cfg.image} \
            -c './run.sh --jitconfig "$(cat /run/coda/jit)"'
          ;;
        act)
          job=$(cat /inputs/job)
          # The bundle carries the commit to test as refs/coda-ci/head.
          git init --quiet /work/src
          cd /work/src
          git fetch --quiet /inputs/repo.bundle refs/coda-ci/head
          git -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
          # No secrets and no cache server; the image is already local.
          act -j "$job" \
            ${lib.concatMapStringsSep " " (label: "-P ${label}=${lib.escapeShellArg cfg.image}") labels} \
            --pull=false --rm --no-cache-server --action-offline-mode \
            --action-cache-path /work/act
          ;;
        *)
          echo "unknown mode: $mode" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  options.codaCiGuest = {
    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/catthehacker/ubuntu@sha256:1d8114fb9c1fa5de85c79a31dc6d24d2128753486e46e1cbad0de98d3f9ae966";
      description = "Job image, pinned by digest; act and the GitHub runner both use it.";
    };
    seedArchives = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = "Image archives the seed loads instead of pulling the image (for offline tests).";
    };
    seedRunner = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether the seed caches the GitHub runner tarball.";
    };
  };

  config = {
    system.stateVersion = "26.05";
    networking.hostName = "coda-ci";
    networking.useDHCP = false;
    networking.useNetworkd = true;
    networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
    # Firecracker exposes virtio-net over PCI, so the guest names it ens3,
    # not eth0; match the tap's MAC instead.
    systemd.network.networks."10-tap" = {
      matchConfig.MACAddress = "02:00:00:00:01:02";
      address = [ "10.234.0.2/30" ];
      routes = [ { Gateway = "10.234.0.1"; } ];
    };
    services.openssh.enable = false;
    users.mutableUsers = false;
    users.allowNoPasswordLogin = true;
    systemd.enableEmergencyMode = false;

    microvm = {
      hypervisor = "firecracker";
      socket = "firecracker.sock";
      vcpu = lib.mkDefault 8;
      mem = lib.mkDefault 12288;
      shares = [ ];
      storeOnDisk = true;
      storeDiskType = "erofs";
      interfaces = [ { type = "tap"; id = "fc-coda-ci"; mac = "02:00:00:00:01:02"; } ];
      # Both images are made by the controller in the job directory.
      volumes = [
        { image = "work.img"; mountPoint = "/work"; size = 0; autoCreate = false; }
        { image = "inputs.img"; mountPoint = "/inputs"; size = 0; autoCreate = false; readOnly = true; }
      ];
    };
    fileSystems."/inputs".options = [ "ro" "nodev" "nosuid" "noexec" ];

    virtualisation.docker = {
      enable = true;
      daemon.settings.data-root = "/work/docker";
    };
    systemd.services.docker.unitConfig.RequiresMountsFor = [ "/work" ];

    systemd.services.coda-job = {
      wantedBy = [ "multi-user.target" ];
      wants = [ "docker.service" "network-online.target" ];
      after = [ "docker.service" "network-online.target" ];
      unitConfig.RequiresMountsFor = [ "/work" "/inputs" ];
      environment.HOME = "/root";
      serviceConfig = {
        Type = "oneshot";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        TimeoutStartSec = "3h";
      };
      # Report the status whatever happened, then end the VM: with reboot=k,
      # a guest reboot makes Firecracker exit.
      script = ''
        set +e
        ${lib.getExe job}
        status=$?
        sync
        echo "CODA_JOB_EXIT=$status"
        systemctl reboot --no-block
      '';
    };
  };
}
