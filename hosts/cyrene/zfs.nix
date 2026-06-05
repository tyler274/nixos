{
  config,
  pkgs,
  lib,
  ...
}:

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
  boot.supportedFilesystems = [
    "zfs"
    "ntfs"
  ];
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

  # Nix build sandboxes live in /tmp/nix-build-* on the host side. A dedicated
  # ZFS dataset keeps them off rpool/nixos/root (and therefore out of every
  # snapshot) while still letting large builds (Firefox, LLVM, etc.) grow into
  # whatever pool space is free — a fixed-size tmpfs would kill those builds.
  # sync=disabled is safe for /tmp: the kernel's page cache is the durability
  # guarantee here, not ZFS intent-log.  The dataset must be created once:
  #   sudo zfs create -o mountpoint=legacy \
  #                   -o com.sun:auto-snapshot=false \
  #                   -o sync=disabled \
  #                   rpool/nixos/tmp
  #   sudo chmod 1777 /tmp   # world-writable sticky bit
  fileSystems."/tmp" = {
    device = "rpool/nixos/tmp";
    fsType = "zfs";
    options = [
      "zfsutil"
      "X-mount.mkdir"
    ];
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

  # The ZVOL swap device is disabled because it was causing issues with the
  # kernel. The ARC cache was not able to keep up with the swap requests, and
  # the kernel was swapping out pages that were still in use.
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

    # Game data: large, constantly changing, fully re-downloadable.
    # Each lives on its own dataset (com.sun:auto-snapshot=false + this entry)
    # so the recursive home snapshot doesn't bloat the pool with game binaries.
    datasets."rpool/nixos/home/luluco/steam" = {
      autosnap = false;
      autoprune = false;
    };
    datasets."rpool/nixos/home/luluco/anime-game-launcher" = {
      autosnap = false;
      autoprune = false;
    };
    datasets."rpool/nixos/home/luluco/honkers-railway-launcher" = {
      autosnap = false;
      autoprune = false;
    };
    datasets."rpool/nixos/home/luluco/sleepy-launcher" = {
      autosnap = false;
      autoprune = false;
    };
    datasets."rpool/nixos/home/luluco/wavey-launcher" = {
      autosnap = false;
      autoprune = false;
    };

    datasets."rpool/nixos/tmp" = {
      autosnap = false;
      autoprune = false;
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
      "change-key"
      "compression"
      "create"
      "mount"
      "mountpoint"
      "receive"
      "rollback"
      "bookmark"
      "hold"
      "send"
      "snapshot"
      "destroy"
    ];
    localTargetAllow = [
      "change-key"
      "compression"
      "create"
      "mount"
      "mountpoint"
      "receive"
      "rollback"
      "bookmark"
      "hold"
      "send"
      "snapshot"
      "destroy"
    ];
    commonArgs = [
      ''--sshoption="UserKnownHostsFile=/etc/syncoid/.ssh/known_hosts"''
      "--compress=zstd-fast"
      "--recursive"
      # NOTE: do NOT put --sendoptions here. The NixOS syncoid module always
      # appends its own `--sendoptions <value>` at the end of the command, so
      # any --sendoptions in commonArgs would be silently overridden (Getopt
      # last-value-wins). Set sendOptions per-command instead.
    ];
    # Remote replication to rsync.net is pending SSH setup (the key at
    # /etc/syncoid/.ssh/id_rsa does not exist yet and the host is unreachable).
    # Leave it disabled until the key/known_hosts are provisioned, otherwise its
    # ExecStopPost `zfs unallow` races the local job and revokes the shared
    # rpool/nixos send/snapshot permissions mid-run ("permission denied").
    # commands."rpool/nixos" = {
    #   source = "rpool/nixos";
    #   target = "syncoid@zh2883b.rsync.net:data1/Cyrene/rpool/nixos";
    #   sendOptions = "w";
    #   extraArgs = [ "--use-hold" ];
    # };
    commands."rpool/nixos-local" = {
      source = "rpool/nixos";
      target = "local-backup/cyrene/rpool/nixos";
      # Raw send preserves the on-disk encrypted blocks; the local-backup pool
      # never needs to hold or know the encryption key.
      sendOptions = "w";
      # Place a ZFS hold on the last-sent source snapshot so sanoid's autoprune
      # cannot delete it between syncoid runs. Without this, sanoid could prune
      # the anchor snapshot and force a full resend on the next run. The hold is
      # released automatically after the next successful incremental send.
      extraArgs = [
        "--use-hold"
        # rpool/nixos/tmp is a no-snapshot build-sandbox dataset; there is
        # nothing worth backing up there and it could be enormous mid-build.
        "--exclude-datasets=rpool/nixos/tmp"
      ];
    };
  };

  # The syncoid NixOS module only delegates ZFS permissions on the *target* if
  # that dataset (or its parent) already exists; otherwise the zfs-allow
  # pre-hook is a silently-ignored no-op and the actual `zfs receive` fails with
  # "permission denied". The local-backup pool is only imported by this config
  # (boot.zfs.extraPools), never provisioned, so create the container datasets
  # that hold the backup before syncoid runs. canmount=off/mountpoint=none keeps
  # these intermediate containers from mounting anywhere; the received
  # rpool/nixos tree carries its own (raw, encrypted) properties.
  systemd.services.syncoid-local-target-init = {
    description = "Create local-backup container datasets for syncoid";
    after = [ "zfs-import.target" ];
    requiredBy = [ "syncoid-rpool-nixos-local.service" ];
    before = [ "syncoid-rpool-nixos-local.service" ];
    path = [ pkgs.zfs ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for ds in local-backup/cyrene local-backup/cyrene/rpool; do
        if ! zfs list -H "$ds" >/dev/null 2>&1; then
          zfs create -o canmount=off -o mountpoint=none "$ds"
        fi
      done
    '';
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
    users = [
      "luluco"
      "phainon"
    ];
  };

  users.users.root.initialHashedPassword = "$6$31uKiv3HbrCU2pbC$D9qnquW32p.8cZH5yz.7j5ExFywS.6j2gii.bqZIRDj551HI2WO5yUiMsUUg0nP.KAXWtSEOj0.VWsXt0uAqt1";
}
