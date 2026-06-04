# TODO: rename `networking.hostName` to the actual laptop hostname,
# regenerate hardware-configuration.nix with `nixos-generate-config --root /mnt`
# during install, and pin `home.stateVersion` / `system.stateVersion` to the
# install-time NixOS release.

{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/desktop-common.nix
    ./hardware-configuration.nix
  ];

  networking = {
    hostName = "laptop";
    networkmanager.enable = true;
    nftables.enable = true;
    firewall.enable = true;
  };

  services.thermald.enable = true;
  services.power-profiles-daemon.enable = true;

  services.fstrim.enable = true;

  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;
  hardware.cpu.amd.updateMicrocode = lib.mkDefault true;

  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  users.users.luluco = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "scanner" "lp" ];
  };

  home-manager.users.luluco = { ... }: {
    imports = [
      ../../modules/home/common.nix
      ../../modules/home/desktop.nix
      ../../modules/home/plasma.nix
    ];
    home.stateVersion = "25.11";
  };

  system.stateVersion = "25.11";
}
