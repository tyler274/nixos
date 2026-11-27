{ lib, ... }:

{
  cyrene.agentsPool = {
    enable = (import ./lib.nix { inherit lib; }).agentsPoolCreated;
    disk = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_2TB_S6B0NL0TA08502B";
    mounts = {
      "agents/ccache" = "/var/cache/ccache";
      "agents/coda/src" = "/agents/coda/src";
      "agents/coda/build" = "/agents/coda/build";
      "agents/coda/ci" = "/agents/coda/ci";
    };
    optionalMounts = {
      # luluco's build root for host worktrees (cyrene-host.toml in
      # coda-rust): keeps build output off rpool and out of home snapshots.
      # One-time, then `sudo chown luluco:users /agents/coda/host`:
      #   sudo zfs create -o mountpoint=/agents/coda/host agents/coda/host
      "agents/coda/host" = "/agents/coda/host";
    };
  };

  imports = [
    ./agents.nix
    ./boot.nix
    ./filesystems.nix
    ./game-home.nix
    ./maintenance.nix
    ./sanoid.nix
    ./syncoid.nix
    ./home.nix
  ];
}
