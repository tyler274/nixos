# Minimal bootstrap config — install this first, boot in, then nixos-rebuild switch to default.nix.
{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/zfs-home.nix
    ./hardware-configuration.nix
    ./zfs
  ];

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

  zramSwap = {
    enable = true;
    algorithm = "zstd";
  };

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
