{ config, pkgs, lib, ... }:

let
  zfsCompatibleKernelPackages = lib.filterAttrs (
    name: kernelPackages:
    (builtins.match "linux_[0-9]+_[0-9]+" name) != null
    && (builtins.tryEval kernelPackages).success
    && (!kernelPackages.${config.boot.zfs.package.kernelModuleAttribute}.meta.broken)
  ) pkgs.linuxKernel.packages;
  latestKernelPackage = lib.last (
    lib.sort (a: b: (lib.versionOlder a.kernel.version b.kernel.version)) (
      builtins.attrValues zfsCompatibleKernelPackages
    )
  );
in
{
  boot.supportedFilesystems = [ "zfs" "ntfs" ];
  boot.kernelParams = [ "console=tty1" ];
  boot.zfs.forceImportRoot = true;
  boot.zfs.requestEncryptionCredentials = [ "rpool" ];
  boot.zfs.extraPools = [ "local-backup" ];
  # Unique per-host ZFS hostid. forceImportRoot above lets the root pool
  # reconcile this on the next boot's forced import without an export (which is
  # impossible for a live system root); see also local-backup, which needs a
  # one-time `zpool import -f local-backup` after the id changes.
  networking.hostId = "69e5e3ea";

  # Note this might jump back and forth as kernels are added or removed.
  boot.kernelPackages = latestKernelPackage;

  boot.loader = {
    efi = {
      efiSysMountPoint = "/boot";
      canTouchEfiVariables = true;
    };
    # lanzaboote replaces the systemd-boot install step with signed-UKI installs.
    systemd-boot.enable = lib.mkForce false;
  };

  boot.lanzaboote = {
    enable = true;
    # sbctl stores the Secure Boot PKI here.  Back this directory up offline.
    pkiBundle = "/etc/secureboot";
  };

  boot.kernel.sysctl = {
    # ZFS manages its own page cache via the ARC; a high swappiness
    # causes the kernel to race against ZFS for the same pages and
    # makes OOM situations much worse. 10 is the standard ZFS recommendation.
    "vm.swappiness" = 10;
    # Tell the kernel to start reclaiming memory earlier (at 3% free)
    # rather than waiting until it is nearly exhausted.
    "vm.min_free_kbytes" = 2097152; # 2 GiB
  };

  boot.zswap = {
    enable = true;
    compressor = "zstd";
    zpool = "zsmalloc";
    maxPoolPercent = 25;
  };

  #swapDevices = [
  #  { device = "/dev/zvol/rpool/swap"; }
  #];

  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "daily";
    };
    trim = {
      enable = true;
      interval = "daily";
    };
  };

  # Take a recursive rpool snapshot on every nixos-rebuild switch so each
  # generation has a matching ZFS checkpoint for block-level rollback.
  system.activationScripts.zfs-generation-snapshot = {
    supportsDryActivation = false;
    text = ''
      ts=$(date +%Y%m%d-%H%M%S)
      ${pkgs.zfs}/bin/zfs snapshot -r rpool/nixos@nixos-$ts 2>/dev/null || true
    '';
  };

  services.sanoid = {
    enable = true;
    interval = "hourly";

    # Home: longer retention; recursive covers all per-user sub-datasets
    # automatically — no per-user entry needed when new users are added.
    datasets."rpool/nixos/home" = {
      autoprune = true;
      autosnap = true;
      hourly = 36;
      daily = 30;
      monthly = 6;
      yearly = 1;
      recursive = true;
    };

    datasets."rpool/nixos/root" = {
      autoprune = true;
      autosnap = true;
      hourly = 36;
      daily = 14;
      monthly = 0;
      yearly = 0;
    };

    datasets."rpool/nixos/var" = {
      autoprune = true;
      autosnap = true;
      hourly = 36;
      daily = 14;
      monthly = 0;
      yearly = 0;
      recursive = true;
    };
  };

  services.syncoid = {
    enable = true;
    sshKey = "/etc/syncoid/.ssh/id_rsa";
    localSourceAllow = [
      "change-key" "compression" "create" "mount" "mountpoint"
      "receive" "rollback" "bookmark" "hold" "send" "snapshot" "destroy"
    ];
    localTargetAllow = [
      "change-key" "compression" "create" "mount" "mountpoint"
      "receive" "rollback" "bookmark" "hold" "send" "snapshot" "destroy"
    ];
    commonArgs = [
      ''--sshoption="UserKnownHostsFile=/etc/syncoid/.ssh/known_hosts"''
      "--compress=zstd-fast"
      "--recursive"
      ''--sendoptions="w"''
    ];
    commands."rpool/nixos" = {
      source = "rpool/nixos";
      target = "syncoid@zh2883b.rsync.net:data1/Cyrene/rpool/nixos";
    };
    commands."rpool/nixos-local" = {
      source = "rpool/nixos";
      target = "local-backup/cyrene/rpool/nixos";
    };
  };

  # Prune snapshots on demand when the pool is getting full, independent of
  # sanoid's hourly schedule. Sanoid's --prune-snapshots respects the retention
  # counts defined above, so this is still a best-effort prune rather than a
  # hard delete of everything.
  # systemd.services.zfs-prune-on-pressure = {
  #   description = "Prune ZFS snapshots when rpool usage exceeds threshold";
  #   serviceConfig = {
  #     Type = "oneshot";
  #     User = "root";
  #   };
  #   script = ''
  #     USED=$(${pkgs.zfs}/bin/zpool list -Hpo capacity rpool)
  #     if [ "$USED" -ge 85 ]; then
  #       echo "rpool at ''${USED}% capacity, pruning snapshots..."
  #       ${pkgs.sanoid}/bin/sanoid --prune-snapshots --verbose
  #     else
  #       echo "rpool at ''${USED}%, no pruning needed."
  #     fi
  #   '';
  # };
  # systemd.timers.zfs-prune-on-pressure = {
  #   wantedBy = [ "timers.target" ];
  #   timerConfig = {
  #     OnBootSec = "10min";
  #     OnUnitActiveSec = "15min";
  #     RandomizedDelaySec = "2min";
  #   };
  # };

  zfsHome = {
    enable = true;
    poolName = "rpool";
    defaultQuota = "500G";
    users = [ "luluco" ];
  };

  users.users.root.initialHashedPassword = "$6$31uKiv3HbrCU2pbC$D9qnquW32p.8cZH5yz.7j5ExFywS.6j2gii.bqZIRDj551HI2WO5yUiMsUUg0nP.KAXWtSEOj0.VWsXt0uAqt1";
}
