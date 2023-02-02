# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:
let
  #unstable = import <nixos-unstable> { config = { allowUnfree = true; }; };
  ups_vendorid = "0764";
  ups_productid = "0501";
  ups_product = "CP1500AVRLCDa";
  ups_serial = "CXEJU2004678";
  ups_password = "buttsmcgeeeeee";
in
{
  imports =
    [
      # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./zfs.nix
    ];
  # I don't have my swap on top of ZFS but suspend/hibernation is still weird.
  #boot.zfs.allowHibernation = true;
  boot.loader.grub.memtest86.enable = true;

  boot.blacklistedKernelModules = [
    # Obscure network protocols
    "ax25"
    "netrom"
    "rose"

    # Old or rare or insufficiently audited filesystems
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
    { device = "/dev/disk/by-uuid/94e48780-db14-4388-9fe0-42f9b5639d61"; }
    { device = "/dev/disk/by-uuid/2c2f46cd-1f7a-4859-b021-e14e2786f7b5"; }
  ];

  # Enable Flakes for better package updates
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # Not sure how to actually adjust system march/mtune with non-legacy configuration.
  nix.settings.system-features = [ "gccarch-znver3" ];
  nix.settings.extra-sandbox-paths = [ config.programs.ccache.cacheDir ];
  # allow unfree packages to be installed from repos. 
  nixpkgs.config.allowUnfree = true;
  #unstable.config.allowUnfree = true;
  # Enable CUDA support for packages that can use it.
  nixpkgs.config.cudaSupport = true;

  # swap this to "mimalloc" to test it. Mainly firefox and chromium/electron things break
  # as they ship their own mallocs. Do other Rust things break? perhaps closed source
  # precompiled things....
  environment.memoryAllocator.provider = "libc";

  # List services that you want to enable:
  services = {
    # Enable the OpenSSH daemon.
    # services.openssh.enable = true;
    openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
      };
      forwardX11 = true;
      ports = [ 42069 ];
    };

    smartd = { 
      enable = true;
    };

    logrotate = {
      enable = true;
    };

    # The general ZFS things that weren't provided by OpenZFS in `zfs.nix`
    zfs = {
      # Checks for checksum errors.
      autoScrub = {
        enable = true;
        interval = "daily";
      };
      # Garbage collects unused flash memory.
      trim = {
        enable = true;
        interval = "daily";
      };
    };

    # Sanoid snapshotting service and Syncoid replication
    sanoid = {
      enable = true;
      interval = "hourly";
      datasets."rpool/nixos" = {
        autoprune = true;
        autosnap = true;
        hourly = 36;
        daily = 30;
        monthly = 3;
        yearly = 1;
        recursive = true;
      };
    };

    syncoid = {
      enable = true;
      # The private ssh-key used to access the backup server. 
      sshKey = "/etc/syncoid/.ssh/id_rsa";
      # Permissions the local `syncoid` user gets to manipulate the local ZFS datasets
      # that are the sources for backups.
      localSourceAllow = [
        "change-key"
        "compression"
        "create"
        "mount"
        "mountpoint"
        "receive"
        "rollback"
        "bookmark"
        "hold"
        "send"
        "snapshot"
        "destroy"
      ];
      # Permissions the local `syncoid` user gets to manipulate local ZFS datasets that
      # are the targets for backups. 
      # NOTE: you must ensure the remote syncoid user has similar permissions. 
      localTargetAllow = [
        "change-key"
        "compression"
        "create"
        "mount"
        "mountpoint"
        "receive"
        "rollback"
        "bookmark"
        "hold"
        "send"
        "snapshot"
        "destroy"
      ];

      # Arguments to the `syncoid` command invocation
      commonArgs = [
        # Without the known hosts file it freaks out connecting to the backup server.
        ''--sshoption="UserKnownHostsFile=/etc/syncoid/.ssh/known_hosts"''
        # Use ZSTD-3 compression, upstream has an unmerged patch to use zstd-adapt to
        # scale the compression based on network conditions, and improve compression over
        # long ranges. 
        "--compress=zstd-fast"
        # Sync child datasets
        "--recursive"
        # Supposed to send the raw snapshot so it can stay encrypted. Seems to not work,
        # check upstream. 
        ''--sendoptions="w"''
      ];

      # The backup command, labeled "rpool/nixos".
      commands."rpool/nixos" = {
        # Source dataset to be synced. 
        source = "rpool/nixos";
        # Target to sync to. 
        target = "syncoid@zh2883b.rsync.net:data1/Sulla/rpool/nixos";
      };
    };

    # Wireguard VPN provider
    mullvad-vpn = {
      enable = true;
    };

    # Firmware update utility
    fwupd = {
      enable = true;
    };

    # Enable the X11 windowing system.
    xserver = {
      enable = true;
      layout = "us";
      # X Server enabled video drivers.
      videoDrivers = [ 
        "nvidia"
        "amdgpu" 
      ];

      # Enables GDM and Gnome.
      #displayManager.gdm.enable = true;
      #desktopManager.gnome.enable = true;

      # Enables SDDM and KDE Plasma.
      displayManager.sddm.enable = true;
      desktopManager.plasma5.enable = true;
    };

    # User device rules
    udev = {
      # Lets the network UPS tools to contact the UPS via the `nut` user. 
      extraRules = ''
        SUBSYSTEM=="usb", ATTRS{idVendor}=="${ups_vendorid}", ATTRS{idProduct}=="${ups_productid}", MODE="664", GROUP="nut", OWNER="nut"
      '';
    };

    # Enable CUPS service to print documents.
    printing = {
      enable = true;
      drivers = [ pkgs.cnijfilter2 ];
    };
    avahi = {
      # for a WiFi printer
      enable = true;
      openFirewall = true;
      nssmdns = true;
    };
    # for an USB printer
    #ipp-usb.enable = true;

    # Enable sound.
    # Remove sound.enable or turn it off if you had it set previously, it seems to cause conflicts with pipewire
    #sound.enable = false;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      jack.enable = true;
    };

    opensnitch.enable = true;

    # enable antivirus clamav and
    # keep the signatures' database updated
    clamav = {
      daemon.enable = true;
      updater.enable = true;
    };

    # Setup Postgres for the meta sploit framework to use. 
    postgresql = {
      enable = true;
      package = pkgs.postgresql;
      enableTCPIP = true;
      authentication = pkgs.lib.mkOverride 10 ''
        local all all trust
        host all all 127.0.0.1/32 trust
        host all all ::1/128 trust
      '';
      initialScript = pkgs.writeText "backend-initScript" ''
        CREATE DATABASE msf;
      '';
    };

    #gnome.glib-networking.enable = true;

    # Uniquity network controller config
    unifi = {
      enable = true;
      unifiPackage = pkgs.unifi;
      openFirewall = true;
    };

    # Emby fork for media server stuff
    jellyfin.enable = true;
  };

  hardware = {
    enableRedistributableFirmware = true;
    # Enable ALL the firmware.
    # enableAllFirmware = true;

    # Update CPU microcode
    cpu = {
      amd.updateMicrocode = true;
      intel.updateMicrocode = true;
    };

    opengl = {
      enable = true;
      driSupport = true;
      # Enables 32bit library support. 
      driSupport32Bit = true;
    };

    # Settings for the Nvidia drivers
    nvidia = {
      # Use the more recent nvidia drivers. 
      package = config.boot.kernelPackages.nvidiaPackages.production;
      # Enables driver modesetting
      modesetting.enable = true;
      # Enables the Nvidia open source kernel modesetting driver. 
      open = true;
    };

    # Bluetooth driver support
    bluetooth = {
      enable = true;
    };

    # Make sure Pulseaudio stays dead.
    pulseaudio.enable = false;
    
    sane = {
      enable = true;
      extraBackends = [ pkgs.sane-airscan ];
      
    };
  };

  # at some point something will make a /var/state/ups directory,
  # chown that to the `nut` user:
  # $ sudo chown nut:nut /var/state/ups
  power.ups = {
    enable = true;
    mode = "standalone";
    # debug by calling the driver:
    # $ sudo NUT_CONFPATH=/etc/nut/ usbhid-ups -u nut -D -a cyberpower
    ups.cyberpower = {
      # find your driver here:
      # https://networkupstools.org/docs/man/usbhid-ups.html
      driver = "usbhid-ups";
      port = "auto";
      description = "CP1500 AVR UPS";
      directives = [
        "vendorid = ${ups_vendorid}"
        "productid = ${ups_productid}"
        "product = ${ups_product}"
      ];
      # this option is not valid for usbhid-ups
      maxStartDelay = null;
    };
    #maxStartDelay = 10;
  };

  users = {
    users = {
      nut = {
        isSystemUser = true;
        group = "nut";
        # it does not seem to do anything with this directory
        # but something errored without it, so whatever
        home = "/var/lib/nut";
        createHome = true;
      };

      # Define a user account. Don't forget to set a password with ‘passwd’.
      luluco = {
        isNormalUser = true;
        extraGroups = [ "wheel" "networkmanager" "scanner" "lp" "docker" ]; # Enable ‘sudo’ for the user.
        packages = with pkgs; [
          firefox-wayland
          thunderbird
          gcc
          wezterm
          cudaPackages.cudatoolkit
          cudaPackages.cudnn
          #cudaPackages.libcublas
          cudaPackages.cutensor
          cudaPackages.tensorrt
          python310
          vscode
          cura
          bitwarden
          (pkgs.writeShellApplication {
            name = "bitwarden-wayland";
            # This actually force disables wayland
            text = "${pkgs.bitwarden}/bin/bitwarden --use-gl=desktop";
          })
          (pkgs.makeDesktopItem {
            name = "BitwardenWayland";
            exec = "bitwarden-wayland";
            desktopName = "BitwardenWayland";
          })
          llvmPackages.bintools
          mold
          rustup
          discord
          # Work around #159267
          (pkgs.writeShellApplication {
            name = "discord-wayland";
            # This actually force disables wayland
            text = "${pkgs.discord}/bin/discord --use-gl=desktop";
            # To try actual wayland support. 
            # text = "${pkgs.discord}/bin/discord --enable-features=WebRTCPipeWireCapturer --enable-features=UseOzonePlatform,WaylandWindowDecorations --ozone-platform=wayland";
          })
          (pkgs.makeDesktopItem {
            name = "DiscordWayland";
            # Does not appear to actually set the icon correctly.
            icon = "Discord";
            exec = "discord-wayland";
            desktopName = "DiscordWayland";
          })
          # Telegram desktop client.
          tdesktop
          # A nix language server.
          rnix-lsp
          # Image creation and editing tool
          krita
          # appimage-run lets you run appimages, but the runtime needs some other packages for certain apps to run.
          # webkitgtk takes a long time to build.... 
          (appimage-run.override { 
            extraPkgs = pkgs: [ 
              nss 
              swt 
              webkitgtk 
              #glib-networking 
            ]; 
          })
          # Not sure if glib-networking is needed here, was from debugging appimage-run above. TEST.
          glib-networking
          # Downloads Youtube videos and other media.
          yt-dlp
          # Give me a system pip.
          python310Packages.pip
          # Discord plugin framework installer.
          betterdiscordctl
          # 3D model and graphics multitool 
          blender
          # really just audiobooks
          spotify
          # controls water pumps. Doesn't work with mine (yet). 
          liquidctl
          # Alternative to steam proton for e.g. Epic Game Store
          lutris
          # drop down terminal.
          yakuake
          # The critically acclaimed MMORPG.
          xivlauncher
          # gives me the dotnet sdk, but can't run e.g. ryujinx without other dependencies. 
          dotnet-sdk_7
          # Get my factor counts up. 	
          authy
          (pkgs.writeShellApplication {
            name = "authy-wayland";
            # Authy actually uses a recent enough Electron to support wayland. 
            text = "${pkgs.authy}/bin/authy --enable-features=UseOzonePlatform,WaylandWindowDecorations --ozone-platform=wayland";
          })
          (pkgs.makeDesktopItem {
            name = "AuthyWayland";
            exec = "authy-wayland";
            desktopName = "AuthyWayland";
          })
          # Better PlayStation remote play client.
          chiaki
          # Finely grained application firewall gui.
          opensnitch-ui
          # Streaming and recording video. Audio processing whenever Nvidia gets on it.  
          obs-studio
          # Get the Glorious Eggroll Proton up to date. 
          protonup-ng
          # Make sure wayland's user facing stuff is available. 
          wayland
          # Media players.
          vlc
          mpv
          # Torrent client
          qbittorrent
          # Matrix chat client (rust)
          stable.fractal-next
          # Matrix homeserver (rust)
          matrix-conduit
          # Red team yourself. 
          metasploit
          # Chromium offshoot for casting and Speechify TTS.
          microsoft-edge
          (pkgs.writeShellApplication {
            name = "microsoft-edge-wayland";
            text = "${pkgs.microsoft-edge}/bin/microsoft-edge --enable-features=WebRTCPipeWireCapturer --enable-features=UseOzonePlatform,WaylandWindowDecorations --ozone-platform=wayland";
          })
          (pkgs.makeDesktopItem {
            name = "MicrosoftEdgeWayland";
            exec = "microsoft-edge-wayland";
            desktopName = "MicrosoftEdgeWayland";
          })
          # Another secure chat client. 
          signal-desktop
          # Supposed to enable adding my ssh key to ssh-agent on kwallet opening,
          # but not configured.
          libsForQt5.ksshaskpass
          # Digital Audio Workstation. 
          reaper
          # Working with MS office documents, spreadsheets, etc. 
          libreoffice-qt
        ];
      };
    };
    groups.nut = { };
  };

  systemd.services = {
    upsd.serviceConfig = {
      User = "nut";
      Group = "nut";
    };
    upsdrv.serviceConfig = {
      User = "nut";
      Group = "nut";
    };
  };

  # Setup some x desktop stuff. 
  xdg = {
    portal = {
      enable = true;
      extraPortals = with pkgs; [
        # The wayland roots portal
        xdg-desktop-portal-wlr
        # The kde portal.
        xdg-desktop-portal-kde
      ];
      #gtkUsePortal = true;
    };
  };

  environment.sessionVariables = {
    # Fixes some Electron apps rendering in wayland. 
    NIXOS_OZONE_WL = "1";

    # Make Firefox behave well on wayland.
    # Might be the only thing the firefox-wayland wrapper does. 
    MOZ_ENABLE_WAYLAND = "1";

    # Let steam find Glorious Egroll Proton
    STEAM_EXTRA_COMPAT_TOOLS_PATHS = "\${HOME}/.steam/root/compatibilitytools.d";
  };

  networking = {
    hostName = "Sulla"; # Define your hostname.
    # Pick only one of the below networking options.
    # wireless.enable = true;  # Enables wireless support via wpa_supplicant.
    networkmanager.enable = true; # Easiest to use and most distros use this by default.

    # Configure network proxy if necessary
    # proxy.default = "http://user:password@proxy:port/";
    # proxy.noProxy = "127.0.0.1,localhost,internal.domain";

    # Open ports in the firewall.
    firewall.allowedTCPPorts = [
      #5432
      #5433
    ];
    # networking.firewall.allowedUDPPorts = [ ... ];
    # Or disable the firewall altogether.
    firewall.enable = true;
  };

  # Set your time zone.
  time.timeZone = "America/New_York";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkbOptions in tty.
  # };

  # Configure keymap in X11
  #   "eurosign:e";
  #   "caps:escape" # map caps to escape.
  # };

  security = {
    # Enables the realtime scheduling priority of user processes.
    rtkit.enable = true;
    # required to run chromium
    chromiumSuidSandbox.enable = true;
    # App Armor broken right now https://github.com/NixOS/nixpkgs/issues/169056
    apparmor.enable = true;

    pam.services.kwallet = {
      name = "kwallet";
      enableKwallet = true;
    };
  };


  environment.etc = {
    # Enable more bluetooth codecs and features in wireplumber and bluez
    "wireplumber/bluetooth.lua.d/51-bluez-config.lua".text = ''
      bluez_monitor.properties = {
        ["bluez5.enable-sbc-xq"] = true,
        ["bluez5.enable-msbc"] = true,
        ["bluez5.enable-hw-volume"] = true,
        ["bluez5.headset-roles"] = "[ hsp_hs hsp_ag hfp_hf hfp_ag ]"
      }
    '';

    # Network UPS Tools daemon config file definition.
    # all this file needs to do is exist
    upsdConf = {
      text = ''
        ALLOW_NO_DEVICE true
      '';
      target = "nut/upsd.conf";
      mode = "0440";
      group = "nut";
      user = "nut";
    };

    # UPS daemon user `nut` configuration.
    upsdUsers = {
      # update upsmonConf MONITOR to match
      text = ''
        [upsmon]
          password = ${ups_password}
          upsmon master
      '';
      target = "nut/upsd.users";
      mode = "0440";
      group = "nut";
      user = "nut";
    };
    # RUN_AS_USER is not a default
    # the rest are from the sample
    # grep -v '#' /nix/store/8nciysgqi7kmbibd8v31jrdk93qdan3a-nut-2.7.4/etc/upsmon.conf.sample
    upsmonConf = {
      text = ''
        RUN_AS_USER nut

        MINSUPPLIES 1
        SHUTDOWNCMD "shutdown -h 0"
        POLLFREQ 5
        POLLFREQALERT 5
        HOSTSYNC 15
        DEADTIME 15
        RBWARNTIME 43200
        NOCOMMWARNTIME 300
        FINALDELAY 5
        MONITOR cyberpower@localhost 1 upsmon ${ups_password} master
      '';
      target = "nut/upsmon.conf";
      mode = "0444";
    };
  };

  programs = {
    # Allowed dynamically linked things expecting a normal ld to work.
    nix-ld.enable = true;
    # Phone link 
    kdeconnect.enable = true;
    # Firejail to restrict the access of the two things that raw dog the internet the
    # most. Microsoft Edge doesn't seem to work with it, possibly due to the issues with 
    # App Armor.
    firejail = {
      enable = true;
      wrappedBinaries = {
        signal-desktop = {
          executable = "${pkgs.signal-desktop}/bin/signal-desktop --enable-features=UseOzonePlatform,WaylandWindowDecorations --ozone-platform=wayland";
          profile = "${pkgs.firejail}/etc/firejail/signal-desktop.profile";
          extraArgs = [ "--env=LC_ALL=C" "--env=GTK_THEME=Adwaita:dark" ];
        };
        firefox = {
          executable = "${pkgs.lib.getBin pkgs.firefox-wayland}/bin/firefox";
          profile = "${pkgs.firejail}/etc/firejail/firefox.profile";
        };
        microsoft-edge = {
          executable = "${pkgs.microsoft-edge}/bin/microsoft-edge";
          profile = "${pkgs.firejail}/etc/firejail/microsoft-edge.profile";
          extraArgs = [ "--enable-features=WebRTCPipeWireCapturer" "--enable-features=UseOzonePlatform,WaylandWindowDecorations" "--ozone-platform=wayland" ];
        };

      };
    };

    # Enables the GUI KDE partition manager
    partition-manager.enable = true;

    steam = {
      enable = true;
      remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
      dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
    };

    # Some programs need SUID wrappers, can be configured further or are
    # started in user sessions.
    # programs.mtr.enable = true;
    # programs.gnupg.agent = {
    #   enable = true;
    #   enableSSHSupport = true;
    # };

    # Friendly nehghborhood SSH Agent.
    ssh.startAgent = true;

    ccache = {
      enable = true;
      packageNames = [ 
        "ffmpeg"
        #"blender"
        "chromium"
        "krita" 
        #"webkitgtk" 
        #"opencv" 
      ];
    };
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    wget
    # Wireguard cli tools
    wireguard-tools
    # 7Zip 
    p7zip
    git
    wayland
    # Still needed for KDE wayland to work on the Nvidia driver.
    egl-wayland
    xwayland
    htop
    nvtop
    pciutils
    usbutils
    nix-index
    dmidecode
    # deez Network UPS Tools
    nut
    # ZFS userspace snapshot management tools
    sanoid
    # deps for Sanoid's syncoid tool
    pv
    mbuffer
    lzop
    zstd
    # Lets you easily, but very destructively, prune snapshots. 
    zfs-prune-snapshots
    # tools 
    smartmontools
    httm
    hydra-check
    # system info needed aha for something
    aha
  ];


  virtualisation = {
    waydroid.enable = true;
    lxd.enable = true;
    lxc = {
      enable = true;
      lxcfs.enable = true;
    };
    docker = {
      enable = true;
      storageDriver = "zfs";
      enableNvidia = true;
      rootless = {
        enable = true;
        setSocketVariable = true;
      };
    };
    #  podman = {
    #    enable = true;

    # Create a `docker` alias for podman, to use it as a drop-in replacement
    #    dockerCompat = true;

    # Required for containers under podman-compose to be able to talk to each other.
    #    defaultNetwork.dnsname.enable = true;

    #    enableNvidia = true; 
    #    extraPackages = [ 
    #      pkgs.zfs 
    #pkgs.fuse-overlayfs
    #    ];
    #  };
    #  containers.storage.settings = {
    #    storage = {
    #      driver = "zfs";
    #      graphroot = "/var/lib/containers/storage";
    #      runroot = "/run/containers/storage";
    #    };
    #  };
  };
  
  nixpkgs.overlays = [
    (self: super: {
      webkitgtk = super.webkitgtk.override { stdenv = super.ccacheStdenv; };
      tdesktop = super.webkitgtk.override { stdenv = super.ccacheStdenv; };

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
      #discord = super.discord.overrideAttrs (
      #  _: {
      #    src = builtins.fetchTarball https://discord.com/api/download?platform=linux&format=tar.gz;
      #postInstall = (_.postInstall or "") + ''
      #  substituteInPlace $out/share/applications/discord.desktop --replace "/bin/discord %U" "/bin/discord %U --use-gl=desktop"
      #''; 
      #  }
      #);
      # ryujinx-master = super.ryujinx.overrideAttrs (
      #   _: {
      #     src = super.fetchFromGitHub {
      #       owner = "Ryujinx";
      #       repo = "Ryujinx";
      #       rev = "e7cf4e6eaf528aa72e27f6ba86259c00813bc776";
      #       sha256 = "fk85Qru+V4YMAlRbjDQRcRWPkqjZEXrESsWXV44vFc8=";
      #     };
      #     version = "e7cf4e6eaf528aa72e27f6ba86259c00813bc776";
      #     dotnetRestoreFlags = [ "--runtime ${pkgs.dotnetCorePackages.sdk_7_0.systemToDotnetRid super.stdenvNoCC.targetPlatform.system}" ];
      #     dotnet-sdk = pkgs.dotnetCorePackages.sdk_7_0;
      #     dotnet-runtime = pkgs.dotnetCorePackages.sdk_7_0;
      #     makeWrapperArgs = [
      #       "--set GDK_BACKEND x11"
      #       "--set SDL_VIDEODRIVER wayland"
      #     ];
      #     patches = [ ];
      #   }
      # );
    })
  ];

  system = {
    # Copy the NixOS configuration file and link it from the resulting system
    # (/run/current-system/configuration.nix). This is useful in case you
    # accidentally delete configuration.nix.
    copySystemConfiguration = false;

    # This value determines the NixOS release from which the default
    # settings for stateful data, like file locations and database versions
    # on your system were taken. It‘s perfectly fine and recommended to leave
    # this value at the release version of the first install of this system.
    # Before changing this value read the documentation for this option
    # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
    stateVersion = "22.11"; # Did you read the comment?

    #autoUpgrade = {
    #  enable = true;
    #  allowReboot = false;
    #  persistent = true;
    #  flake = "github:tyler274/nixos";
    #  flags = [
    #    "--recreate-lock-file"
    #    "--no-write-lock-file"
    #    "-L" # print build logs
    #  ];
    #  dates = "daily";
    #};
  };

}
