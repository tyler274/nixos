{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/desktop-common.nix
    ../../modules/nixos/zfs-home.nix
    ../../modules/nixos/nvidia.nix
    ../../modules/nixos/ccache.nix
    ./hardware-configuration.nix
    ./zfs.nix
  ];

  networking = {
    hostName = "Sulla";
    networkmanager.enable = true;
    nftables.enable = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ ];
    };
  };

  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.production;

  swapDevices = [
    { device = "/dev/disk/by-uuid/94e48780-db14-4388-9fe0-42f9b5639d61"; }
    { device = "/dev/disk/by-uuid/2c2f46cd-1f7a-4859-b021-e14e2786f7b5"; }
  ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
  };

  services.unifi = {
    enable = true;
    unifiPackage = pkgs.unifi;
    mongodbPackage = pkgs.mongodb-7_0;
    openFirewall = true;
  };

  programs.ccache.packageNames = [
    "ffmpeg"
    "blender"
    "chromium"
    "opencv"
    "libreoffice"
  ];

  users.users.luluco = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "scanner" "lp" "docker" ];
  };

  home-manager.users.luluco = { ... }: {
    imports = [
      ../../modules/home/common.nix
      ../../modules/home/desktop.nix
    ];
    home.stateVersion = "22.11";

    home.packages = with pkgs; [
      nvtopPackages.nvidia
      zenith-nvidia
      gwe
      nut
      # Pin CUDA 13.2 (matches NVIDIA cuda-samples upstream target).
      cudaPackages_13_2.cudatoolkit
      cudaPackages_13_2.cudnn
      cudaPackages_13_2.libcutensor
      cudaPackages_13_2.tensorrt
    ];
  };

  system.stateVersion = "22.11";
}
