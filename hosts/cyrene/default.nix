{ config, pkgs, lib, inputs, ... }:

let
  ups_vendorid = "0764";
  ups_productid = "0501";
  ups_product = "CP1500AVRLCDa";
  ups_password = "buttsmcgeeeeee";
in
{
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/desktop-common.nix
    ../../modules/nixos/zfs-home.nix
    ./hardware-configuration.nix
    ./zfs.nix
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

  # Temporarily disabled for initial install — re-enable after first boot and run nixos-rebuild switch
  # nixpkgs.config.cudaSupport = true;

  nix.settings.system-features = [
    "kvm"
    "nixos-test"
    "benchmark"
    "big-parallel"
    "gccarch-znver3"
  ];
  nix.settings.extra-sandbox-paths = [ config.programs.ccache.cacheDir ];

  environment.memoryAllocator.provider = "libc";

  boot.loader.grub.memtest86.enable = true;

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

  swapDevices = [
    { device = "/dev/zvol/rpool/swap"; }
  ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
  };

  hardware = {
    enableRedistributableFirmware = true;

    cpu = {
      amd.updateMicrocode = true;
      intel.updateMicrocode = true;
    };

    graphics = {
      enable = true;
      enable32Bit = true;
    };

    nvidia = {
      package = config.boot.kernelPackages.nvidiaPackages.production;
      modesetting.enable = true;
      open = false;
    };

    nvidia-container-toolkit.enable = true;
  };

  services.xserver.videoDrivers = lib.mkForce [ "nvidia" ];

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

  services.sanoid = {
    enable = true;
    interval = "hourly";

    # Home: longer retention; recursive covers all per-user sub-datasets
    # automatically — no per-user entry needed when new users are added.
    datasets."rpool/nixos/home" = {
      autoprune = true;
      autosnap = true;
      hourly = 36;
      daily = 30;
      monthly = 6;
      yearly = 1;
      recursive = true;
    };

    datasets."rpool/nixos/root" = {
      autoprune = true;
      autosnap = true;
      hourly = 36;
      daily = 14;
      monthly = 0;
      yearly = 0;
    };

    datasets."rpool/nixos/var" = {
      autoprune = true;
      autosnap = true;
      hourly = 36;
      daily = 14;
      monthly = 0;
      yearly = 0;
      recursive = true;
    };
  };

  services.syncoid = {
    enable = true;
    sshKey = "/etc/syncoid/.ssh/id_rsa";
    localSourceAllow = [
      "change-key" "compression" "create" "mount" "mountpoint"
      "receive" "rollback" "bookmark" "hold" "send" "snapshot" "destroy"
    ];
    localTargetAllow = [
      "change-key" "compression" "create" "mount" "mountpoint"
      "receive" "rollback" "bookmark" "hold" "send" "snapshot" "destroy"
    ];
    commonArgs = [
      ''--sshoption="UserKnownHostsFile=/etc/syncoid/.ssh/known_hosts"''
      "--compress=zstd-fast"
      "--recursive"
      ''--sendoptions="w"''
    ];
    commands."rpool/nixos" = {
      source = "rpool/nixos";
      target = "syncoid@zh2883b.rsync.net:data1/Cyrene/rpool/nixos";
    };
  };

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

  services.unifi = {
    enable = true;
    unifiPackage = pkgs.unifi;
    mongodbPackage = pkgs.mongodb-7_0;
    openFirewall = true;
  };

  services.jellyfin.enable = true;

  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="${ups_vendorid}", ATTRS{idProduct}=="${ups_productid}", MODE="664", GROUP="nut", OWNER="nut"
  '';

  power.ups = {
    enable = true;
    mode = "standalone";

    ups.cyberpower = {
      driver = "usbhid-ups";
      port = "auto";
      description = "CP1500 AVR UPS";
      directives = [
        "vendorid = ${ups_vendorid}"
        "productid = ${ups_productid}"
        "product = ${ups_product}"
      ];
      maxStartDelay = null;
    };

    upsd.listen = [
      { address = "127.0.0.1"; port = 3493; }
      { address = "::1"; port = 3493; }
    ];

    users.upsmon = {
      passwordFile = "${pkgs.writeText "upsmon-password" ups_password}";
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

  # Temporarily disabled for initial install — re-enable after first boot
  # programs.ccache = {
  #   enable = true;
  #   packageNames = [
  #     "ffmpeg"
  #     "blender"
  #     "chromium"
  #     "opencv"
  #     "libreoffice"
  #   ];
  # };

  virtualisation = {
    waydroid.enable = true;
    incus = {
      enable = true;
      bucketSupport = false;
    };
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

  nixpkgs.overlays = [
    (self: super: {
      openldap = super.openldap.overrideAttrs (_: { doCheck = false; });
    })
    (self: super: {
      llvmPackages = super.llvmPackages // {
        bintools = super.lib.lowPrio super.llvmPackages.bintools;
      };
      llvmPackages_19 = super.llvmPackages_19 // {
        bintools = super.lib.lowPrio super.llvmPackages_19.bintools;
      };
    })
    (self: super: {
      ccacheWrapper = super.ccacheWrapper.override {
        extraConfig = ''
          export CCACHE_COMPRESS=1
          export CCACHE_DIR="${config.programs.ccache.cacheDir}"
          export CCACHE_UMASK=007
          if [ ! -d "$CCACHE_DIR" ]; then
            echo "====="
            echo "Directory '$CCACHE_DIR' does not exist"
            echo "Please create it with:"
            echo "  sudo mkdir -m0770 '$CCACHE_DIR'"
            echo "  sudo chown root:nixbld '$CCACHE_DIR'"
            echo "====="
            exit 1
          fi
          if [ ! -w "$CCACHE_DIR" ]; then
            echo "====="
            echo "Directory '$CCACHE_DIR' is not accessible for user $(whoami)"
            echo "Please verify its access permissions"
            echo "====="
            exit 1
          fi
        '';
      };
    })
  ];

  users = {
    users = {
      nut = {
        isSystemUser = true;
        group = "nut";
        home = "/var/lib/nut";
        createHome = true;
      };

      luluco = {
        isNormalUser = true;
        extraGroups = [ "wheel" "networkmanager" "scanner" "lp" "docker" ];
      };
    };
    groups.nut = { };
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
      # Re-enable after uncommenting nixpkgs.config.cudaSupport = true above.
      # cudaPackages_13_2.cudatoolkit
      # cudaPackages_13_2.cudnn
      # cudaPackages_13_2.libcutensor
      # cudaPackages_13_2.tensorrt
    ];
  };

  system.stateVersion = "22.11";
}
