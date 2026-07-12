# Minimal bootstrap config — install this first, boot in, then nixos-rebuild switch to default.nix.
{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/zfs-home.nix
    ./hardware-configuration.nix
    ./radios.nix
    # Deliberately NOT ./zfs (the whole dir): game-home.nix mounts datasets
    # that only exist after the post-install step, and sanoid/syncoid assume
    # the local-backup pool. Import only what a fresh install needs to boot.
    ./zfs/boot.nix
    ./zfs/filesystems.nix
    ./zfs/home.nix
  ];

  # boot.nix imports the local-backup pool, which is created post-install;
  # a missing extraPool fails zfs-import at every boot of the bootstrap system.
  boot.zfs.extraPools = lib.mkForce [ ];

  # During bootstrap the rpool/docker dataset may not exist yet (or may be in
  # flux); don't let its mount unit drag the system into emergency mode.
  # Option lists merge, so this appends to the options set in zfs/filesystems.nix.
  fileSystems."/var/lib/docker".options = [ "nofail" ];

  networking = {
    hostName = "Cyrene";
    networkmanager.enable = true;
    firewall.allowedTCPPorts = [ 22 ];
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    ports = [ 42069 ];
  };

  swapDevices = [
    { device = "/dev/zvol/rpool/swap"; }
  ];

  # No zramSwap here: ./zfs/boot.nix already enables boot.zswap, and zram +
  # zswap are mutually exclusive (both compress swap pages in RAM).

  # common.nix enables incus; not needed for the bootstrap install.
  virtualisation.incus = {
    enable = lib.mkForce false;
    ui.enable = lib.mkForce false;
  };

  # Docker (zfs storage driver) is disabled during bootstrap: with the
  # /var/lib/docker mount marked nofail above, a skipped mount would let
  # dockerd plant its per-layer datasets on rpool/nixos/var/lib — the exact
  # snapshot/replication flood rpool/docker exists to prevent. The full
  # Cyrene config re-enables it once the pool layout is settled.
  virtualisation.docker.enable = lib.mkForce false;

  hardware.enableRedistributableFirmware = true;

  environment.systemPackages = with pkgs; [ git sbctl ];

  users = {
    users = {
      luluco = {
        isNormalUser = true;
        extraGroups = [ "wheel" "networkmanager" ];
        openssh.authorizedKeys.keyFiles = lib.optional
          (builtins.pathExists ./authorized_keys)
          ./authorized_keys;
      };
    };
  };

  zfsHome = {
    enable = true;
    poolName = "rpool";
    defaultQuota = "500G";
    users = [ "luluco" ];
  };

  system.stateVersion = "25.11";
}
