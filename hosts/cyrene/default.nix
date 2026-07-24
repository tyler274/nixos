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
    ../../modules/nixos/xtool-studio
    ./hardware-configuration.nix
    ./radios.nix
    ./scratch.nix
    ./zfs
    inputs.aagl.nixosModules.default
  ];

  # Run GC daily (more frequently than the default weekly) given rpool space pressure.
  # Retention window matches common.nix (30d) so Nix generations and ZFS
  # generation snapshots share the same 30-day horizon.
  nix.gc.dates = lib.mkForce "daily";

  networking = {
    hostName = "Cyrene";
    networkmanager.enable = true;
    nftables.enable = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ ];
    };
  };

  # Swap on the repurposed Samsung 980 PRO (replaced the old 870 EVO).
  # part1 = 512 GiB swap; part2 = Nix build scratch (see scratch.nix).
  # Encrypted with a fresh random key on every boot so no sensitive data is
  # written to disk in plaintext. zswap (zfs/boot.nix) requires at least one
  # physical swap device as its backing store, so this must stay non-empty.
  swapDevices = [
    { device = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_2TB_S6B0NL0TA08502B-part1"; randomEncryption.enable = true; }
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

  # ~/.ssh ended up root-owned after the reinstall (root wrote into it before
  # the user ever logged in), which made home-manager-luluco.service fail at
  # boot: "ln: failed to create symbolic link '/home/luluco/.ssh/config':
  # Permission denied". Applied at boot and on every activation.
  systemd.tmpfiles.rules = [
    "d /home/luluco/.ssh 0700 luluco users -"
  ];

  # Modern Nix expects ~/.local/state/nix/profiles to already exist before it
  # will write a profile generation into it, but nothing creates that
  # directory ahead of time. On the very first home-manager activation for a
  # user (e.g. this first switch from CyreneMinimal to the full Cyrene
  # config), that leaves nothing there yet and activation aborts with
  # "could not find suitable profile directory". Piggyback on the
  # home-manager-<user> unit's own (correct) RequiresMountsFor=$HOME
  # ordering so this runs after the ZFS home dataset is mounted, as the same
  # user, before activation proper.
  # https://github.com/nix-community/home-manager/issues/4403
  systemd.services."home-manager-luluco".preStart = lib.mkBefore ''
    mkdir -p "$HOME/.local/state/nix/profiles"
  '';

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
      #cemu
      #dolphin-emu
      wine
      capacities
      kubectl
      pods
      hydra-check
      #galaxy-buds-client
      calibre
      #krita
    ];
  };

  system.stateVersion = "25.11";
}
