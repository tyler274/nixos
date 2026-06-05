{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:

{
  imports = [
    ./hardening.nix
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
      "https://cuda-maintainers.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
    ];
    system-features = [
      "kvm"
      "nixos-test"
      "benchmark"
      "big-parallel"
      "gccarch-znver3"
    ];
    # Restrict Nix daemon access to the @users group (excludes system services
    # that have no business evaluating Nix expressions).
    allowed-users = [ "@users" ];
  };

  nix.gc = {
    automatic = true;
    dates = "hourly";
    options = "--delete-older-than 30d";
  };

  nixpkgs.config.allowUnfree = true;

  time.timeZone = "America/Phoenix";
  i18n.defaultLocale = "en_US.UTF-8";

  security.rtkit.enable = true;

  environment.memoryAllocator.provider = "libc";

  # Enable mimalloc's hardened build: randomises heap segment placement,
  # adds guard pages, and validates free-list integrity. Trades a small
  # amount of throughput for meaningful use-after-free/heap-overflow
  # detection. See: https://github.com/microsoft/mimalloc#secure-mode
  #nixpkgs.overlays = [
  #  (final: prev: {
  #    mimalloc = prev.mimalloc.override { secureBuild = true; };
  #  })
  #];

  programs = {
    nix-ld.enable = true;
    ssh.startAgent = true;
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    git
    htop
    ripgrep
    nix-index
    sbctl
    mullvad-vpn
    exfatprogs
    exfat
    ntfs3g
    zfs-prune-snapshots
  ];

  boot.loader.grub.memtest86.enable = true;

  # Modules with no legitimate use on a desktop workstation; reduces kernel
  # attack surface for amateur radio and obscure/legacy filesystems.
  boot.blacklistedKernelModules = [
    "ax25"
    "netrom"
    "rose"

    "adfs"
    "affs"
    "bfs"
    "befs"
    "cramfs"
    "efs"
    "erofs"
    "exofs"
    "freevxfs"
    "f2fs"
    "hfs"
    "hpfs"
    "jfs"
    "minix"
    "nilfs2"
    "ntfs"
    "omfs"
    "qnx4"
    "qnx6"
    "sysv"
    "ufs"
  ];

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      X11Forwarding = true;
    };
    ports = [ 42069 ];
  };

  services.smartd.enable = true;
  services.logrotate.enable = true;

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql;
    enableTCPIP = true;
    authentication = lib.mkOverride 10 ''
      local all all trust
      host all all 127.0.0.1/32 trust
      host all all ::1/128 trust
    '';
    initialScript = pkgs.writeText "backend-initScript" ''
      CREATE DATABASE msf;
    '';
  };

  services.jellyfin.enable = true;

  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="0764", ATTRS{idProduct}=="0501", MODE="664", GROUP="nut", OWNER="nut"
  '';

  power.ups = {
    enable = true;
    mode = "standalone";

    ups.cyberpower = {
      driver = "usbhid-ups";
      port = "auto";
      description = "CP1500 AVR UPS";
      directives = [
        "vendorid = 0764"
        "productid = 0501"
        "product = CP1500AVRLCDa"
      ];
      maxStartDelay = null;
    };

    upsd.listen = [
      {
        address = "127.0.0.1";
        port = 3493;
      }
      {
        address = "::1";
        port = 3493;
      }
    ];

    users.upsmon = {
      passwordFile = "${pkgs.writeText "upsmon-password" "buttsmcgeeeeee"}";
      upsmon = "primary";
    };

    upsmon = {
      monitor.cyberpower = {
        system = "cyberpower@localhost";
        powerValue = 1;
        user = "upsmon";
        type = "primary";
      };
      settings = {
        MINSUPPLIES = 1;
        SHUTDOWNCMD = "\"${pkgs.systemd}/bin/shutdown -h 0\"";
        POLLFREQ = 5;
        POLLFREQALERT = 5;
        HOSTSYNC = 15;
        DEADTIME = 15;
        RBWARNTIME = 43200;
        NOCOMMWARNTIME = 300;
        FINALDELAY = 5;
      };
    };
  };

  users = {
    users.nut = {
      isSystemUser = true;
      group = "nut";
      home = "/var/lib/nut";
      createHome = true;
    };
    groups.nut = { };
  };

  virtualisation = {
    waydroid.enable = true;
    incus.enable = true;
    lxc = {
      enable = true;
      lxcfs.enable = true;
    };
    docker = {
      enable = true;
      storageDriver = "zfs";
      rootless = {
        enable = true;
        setSocketVariable = true;
      };
    };
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    extraSpecialArgs = { inherit inputs; };
    sharedModules = [ inputs.plasma-manager.homeModules.plasma-manager ];
  };
}
