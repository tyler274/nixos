{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/desktop-common.nix
    ../../modules/nixos/amd.nix
    ../../modules/nixos/mold.nix
    # Superseded by the Plasma 6.7 overlay (flake.nix): 6.7 rewrote the DRM
    # color pipeline, so the manual KWin source patching is no longer needed
    # and its 6.6-era patch would fail to apply against 6.7 sources.
    # ../../modules/nixos/kwin-git.nix
    ../../modules/nixos/zfs-home.nix
    ../../modules/nixos/nvidia.nix
    ../../modules/nixos/ollama.nix
    ../../modules/nixos/ccache.nix
    ../../modules/nixos/steam-usb.nix
    ./hardware-configuration.nix
    ./zfs
    inputs.aagl.nixosModules.default
  ];

  # Tighter retention than modules/nixos/common.nix (30d) — rpool is space-constrained.
  nix.gc = {
    dates = lib.mkForce "daily";
    options = lib.mkForce "--delete-older-than 7d";
  };

  networking = {
    hostName = "Cyrene";
    networkmanager.enable = true;
    nftables.enable = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ ];
    };
  };

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

  #programs.ccache.packageNames = [
  #  "ffmpeg"
  #  "blender"
  #  "firefox"
  #  "firefox-unwrapped"
  #  "chromium"
  #  "chromium-unwrapped"
  #  "opencv"
  #  "libreoffice"
  #  "libreoffice-fresh"
  #  "libreoffice-qt-fresh"
  #  "electron"
  #  "electron-unwrapped"
  #  "kdePackages.qtwebengine"
  #  "qt6.qtwebengine"
  #  "kdePackages.krita"
  #  "onnxruntime"
  #];
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

  #nixpkgs.overlays = [
  #  (self: super: {
  #    openldap = super.openldap.overrideAttrs (_: { doCheck = false; });
  #  })
  #  (self: super: {
  #    binutils = super.lib.hiPrio super.binutils;
  #    binutils-unwrapped = super.lib.hiPrio super.binutils-unwrapped;
  #  })
  #];

  users.users.luluco = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "scanner" "lp" "docker" ];
  };

  # Second account. NixOS users are declarative: without this block there is no
  # phainon entry in /etc/passwd, so passwd/login/chown-by-name all fail even
  # though the ZFS home dataset is already mounted at /home/phainon. mutableUsers
  # defaults to true, so `passwd phainon` works after the next rebuild. Add
  # "wheel" here if this account needs sudo.
  users.users.phainon = {
    isNormalUser = true;
    extraGroups = [ "networkmanager" ];
  };

  home-manager.users.luluco = { ... }: {
    imports = [
      ../../modules/home/common.nix
      ../../modules/home/desktop.nix
      ../../modules/home/plasma.nix
    ];
    home.stateVersion = "25.11";

    home.packages = with pkgs; [
      nvtopPackages.nvidia
      zenith-nvidia
      gwe
      nut
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
      #krita
    ];
    home.sessionVariables = {
      SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/.bitwarden-ssh-agent.sock";
    };
  };

  system.stateVersion = "25.11";
}
