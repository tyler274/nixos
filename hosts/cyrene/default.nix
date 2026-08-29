{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

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
    ../../modules/nixos/chitubox
    ./hardware-configuration.nix
    ./radios.nix
    ./scratch.nix
    ./ccache.nix
    ./zfs
    inputs.aagl.nixosModules.default
  ];

  # Automatic GC OFF during the from-source znver5 world-rebuild campaign
  # (see gccarch-znver5 below): `nixos-rebuild boot` never registers a GC
  # root until the ENTIRE system closure builds successfully, so every
  # source fetch and every leaf package compiled across dozens of
  # multi-hour --keep-going attempts sits unreferenced in the store the
  # whole time. GC's mark-and-sweep doesn't care about --delete-older-than
  # for these - that flag only prunes old *generations*; anything that was
  # never a root gets swept on every run, age be damned. Confirmed via
  # nix-gc.service's last run: 14744 store paths / 189.8 GiB deleted in one
  # sweep, including bare source tarballs and fully-built leaf packages -
  # a full day of build progress erased, forcing refetches and recompiles
  # on the next attempt. rpool/nixos/root is at 9% used / 1.1T free (`df -h
  # /nix/store`), so there's no actual space pressure justifying daily
  # sweeps right now. Re-enable (`nix.gc.automatic = true;` + a `dates`)
  # once this generation lands and stabilizes, or run
  # `sudo nix-collect-garbage --delete-older-than 30d` manually if rpool
  # usage climbs mid-campaign.
  # nix.gc.automatic = lib.mkForce "false";

  nix.settings = {
    # This host builds the world from source (-march=znver5 below), so the
    # cachix substituters in common.nix can never hit - they only serve
    # standard-arch builds - yet each derivation still costs a narinfo query
    # per cache. Keep only cache.nixos.org: it still serves the arch-
    # independent fixed-output sources (tarballs, cargo/go/npm vendor dirs),
    # which beats fetching them from upstream project sites.
    substituters = lib.mkForce [ "https://cache.nixos.org" ];
    # Cache "not in this cache" answers for 24h instead of the default 1h so
    # iterative fix-and-rebuild runs don't re-query thousands of known misses.
    narinfo-cache-negative-ttl = 86400;
  };

  # Target the Ryzen 9 9950X3D (Zen 5). Overrides the plain "x86_64-linux"
  # mkDefault in hardware-configuration.nix; every package is compiled with
  # -march=znver5. Requires the gccarch-znver5 system-feature (common.nix) so
  # the daemon accepts derivations marked with that requirement. Note: the
  # resulting system will not boot on pre-Zen-5 (no AVX-512/newer ISA) CPUs.
  nixpkgs.hostPlatform = {
    system = "x86_64-linux";
    gcc.arch = "znver5";
    gcc.tune = "znver5";
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

  # Swap on the Samsung 990 PRO (took over swap+scratch duty from the 980
  # PRO, which now holds the persistent ccache - see ccache.nix).
  # part1 = 512 GiB swap; part2 = Nix build scratch (see scratch.nix).
  # Encrypted with a fresh random key on every boot (crypttab in scratch.nix)
  # so no sensitive data is written to disk in plaintext. zswap (zfs/boot.nix)
  # requires at least one physical swap device as its backing store, so this
  # must stay non-empty. Do not switch this back to randomEncryption: that
  # path waits on systemd-modules-load, which NVIDIA regularly overruns.
  swapDevices = [
    {
      device = "/dev/mapper/swap";
      options = [ "x-systemd.requires=systemd-cryptsetup@swap.service" ];
    }
  ];

  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.latest;

  services.earlyoom = {
    enable = false;
    # Kill when free RAM drops below 5% (~3.2 GiB) or free swap below 10%.
    freeMemThreshold = 5;
    freeSwapThreshold = 10;
    # Prefer killing nix build workers over other processes.
    extraArgs = [
      "--prefer"
      "^nix"
    ];
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
    extraGroups = [
      "wheel"
      "networkmanager"
      "scanner"
      "lp"
      "docker"
    ];
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
      #capacities
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
