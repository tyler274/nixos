{ config, pkgs, lib, ... }:

{
  boot.supportedFilesystems = [ "zfs" "ntfs" ];
  boot.zfs.forceImportRoot = false;
  boot.zfs.requestEncryptionCredentials = true;
  networking.hostId = "48cd5bc1";

  boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;

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
      target = "syncoid@zh2883b.rsync.net:data1/Sulla/rpool/nixos";
    };
  };

  zfsHome = {
    enable = true;
    poolName = "rpool";
    defaultQuota = "500G";
  };

  users.users.root.initialHashedPassword = "$6$vb/z0RxvkSqBDVlE$GuJFN90Karj9Ao9uQ/4vBdzMrZImnZeTHhQpQ6Smskrhj.udjK0irW89rtsnVicAlNb5re.vloBp7EDFyTxKx.";
}
