{ config, pkgs, lib, ... }:

{
  boot.supportedFilesystems = [ "zfs" "ntfs" ];
  boot.zfs.forceImportRoot = false;
  boot.zfs.requestEncryptionCredentials = "prompt";
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

  zfsHome = {
    enable = true;
    poolName = "rpool";
    defaultQuota = "500G";
  };

  users.users.root.initialHashedPassword = "$6$vb/z0RxvkSqBDVlE$GuJFN90Karj9Ao9uQ/4vBdzMrZImnZeTHhQpQ6Smskrhj.udjK0irW89rtsnVicAlNb5re.vloBp7EDFyTxKx.";
}
