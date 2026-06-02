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
    inputs.aagl.nixosModules.default
  ];

  networking = {
    hostName = "Cyrene";
    networkmanager.enable = true;
    nftables.enable = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ ];
    };
  };

  # Remove once Bitwarden releases a new version.
  nixpkgs.config.permittedInsecurePackages = [
    "electron-39.8.10"
  ];

  # Additional swap on the Samsung 870 EVO; encrypted with a fresh random
  # key on every boot so no sensitive data is written to disk in plaintext.
  swapDevices = [
    { device = "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PXNM0T802521D"; randomEncryption.enable = true; }
  ];

  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.latest;

  services.earlyoom = {
    enable = false;
    # Kill when free RAM drops below 5% (~3.2 GiB) or free swap below 10%.
    freeMemThreshold = 5;
    freeSwapThreshold = 10;
    # Prefer killing nix build workers over other processes.
    extraArgs = [ "--prefer" "^nix" ];
  };

  programs.ccache.packageNames = [
    "ffmpeg"
    "blender"
    # "chromium-bin"
    "opencv"
    # "libreoffice-qt"
    # "electron"
  ];
  # programs.chromium.enablePlasmaBrowserIntegration = true;
  programs.gamescope.enable = true;
  programs.gamemode.enable = true;

  # Enable the anime game launchers
  programs.anime-game-launcher.enable = true; # Adds launcher and /etc/hosts rules
  programs.anime-games-launcher.enable = true;
  programs.honkers-railway-launcher.enable = true;
  programs.honkers-launcher.enable = true;
  programs.wavey-launcher.enable = true;
  programs.sleepy-launcher.enable = true;

  nixpkgs.overlays = [
    (self: super: {
      openldap = super.openldap.overrideAttrs (_: { doCheck = false; });
    })
    (self: super: {
      binutils = super.lib.hiPrio super.binutils;
      binutils-unwrapped = super.lib.hiPrio super.binutils-unwrapped;
    })
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
    home.stateVersion = "25.11";

    home.packages = with pkgs; [
      nvtopPackages.nvidia
      zenith-nvidia
      gwe
      nut
      #notion-app
      code-cursor-fhs
      # Pin CUDA 13.2 (matches NVIDIA cuda-samples upstream target).
      # Re-enable after uncommenting nixpkgs.config.cudaSupport = true above.
      # cudaPackages_13_2.cudatoolkit
      # cudaPackages_13_2.cudnn
      # cudaPackages_13_2.libcutensor
      # cudaPackages_13_2.tensorrt
      openssl
      cemu
      dolphin-emu
      wine
      capacities
      kubectl
      pods
      hydra-check
      galaxy-buds-client
      calibre
    ];
    home.sessionVariables = {
      SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/.bitwarden-ssh-agent.sock";
    };
  };

  system.stateVersion = "25.11";
}
