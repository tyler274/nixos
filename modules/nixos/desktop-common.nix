{
  config,
  pkgs,
  lib,
  ...
}:

{
  services.xserver = {
    enable = true;
    xkb.layout = "us";
    videoDrivers = lib.mkDefault [ "modesetting" ];
  };

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    wayland.compositor = "kwin";
  };
  services.desktopManager.plasma6.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };

  hardware = {
    bluetooth = {
      enable = true;
      package = pkgs.bluez5-experimental;
    };
    sane = {
      enable = true;
      extraBackends = [ pkgs.sane-airscan ];
    };
  };

  services.pulseaudio.enable = false;

  services.printing = {
    enable = true;
    drivers = [ pkgs.cnijfilter2 ];
  };

  services.avahi = {
    enable = true;
    openFirewall = true;
    nssmdns4 = true;
  };

  services.opensnitch.enable = true;

  services.clamav = {
    daemon.enable = true;
    updater.enable = true;
  };

  services.mullvad-vpn.enable = true;
  services.fwupd.enable = true;

  programs.kdeconnect.enable = true;
  programs.partition-manager.enable = true;

  services.jackett = {
    enable = true;
  };

  programs.obs-studio = {
    enable = true;
    enableVirtualCamera = true;
  };

  programs.firejail = {
    enable = true;
    wrappedBinaries = {
      signal-desktop = {
        executable = "${pkgs.signal-desktop}/bin/signal-desktop --enable-features=UseOzonePlatform,WaylandWindowDecorations --ozone-platform=wayland";
        profile = "${pkgs.firejail}/etc/firejail/signal-desktop.profile";
        extraArgs = [
          "--env=LC_ALL=C"
          "--env=GTK_THEME=Adwaita:dark"
        ];
      };
      firefox = {
        executable = "${lib.getBin pkgs.firefox-bin}/bin/firefox";
        profile = "${pkgs.firejail}/etc/firejail/firefox.profile";
      };
      thunderbird = {
        executable = "${lib.getBin pkgs.thunderbird-bin}/bin/thunderbird";
        profile = "${pkgs.firejail}/etc/firejail/thunderbird-wayland.profile";
      };
      microsoft-edge = {
        executable = "${pkgs.microsoft-edge}/bin/microsoft-edge";
        profile = "${pkgs.firejail}/etc/firejail/microsoft-edge.profile";
        extraArgs = [
          "--enable-features=WebRTCPipeWireCapturer"
          "--enable-features=UseOzonePlatform,WaylandWindowDecorations"
          "--ozone-platform=wayland"
        ];
      };
    };
  };

  # Allow native messaging host integrations to work
  # Did not actually fix the problem unfortunately.
  #environment.etc."firejail/firefox.local".text = ''
  #  ignore nodbus
  #'';

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
  };

  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      kdePackages.xdg-desktop-portal-kde
    ];
  };

  security = {
    apparmor.enable = true;
    # Terminate confined processes that lack an AppArmor profile rather than
    # running them unconfined; prevents profile-less software from silently
    # bypassing MAC enforcement.
    apparmor.killUnconfinedConfinables = true;
    chromiumSuidSandbox.enable = true;
    pam.services.kwallet = {
      name = "kwallet";
      enableKwallet = true;
    };
  };

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
    STEAM_EXTRA_COMPAT_TOOLS_PATHS = "\${HOME}/.steam/root/compatibilitytools.d";
  };

  environment.etc = {
    "wireplumber/bluetooth.lua.d/51-bluez-config.lua".text = ''
      bluez_monitor.properties = {
        ["bluez5.enable-sbc-xq"] = true,
        ["bluez5.enable-msbc"] = true,
        ["bluez5.enable-hw-volume"] = true,
        ["bluez5.headset-roles"] = "[ hsp_hs hsp_ag hfp_hf hfp_ag ]"
      }
    '';
  };

  # Remove once Bitwarden ships with a non-insecure Electron version.
  nixpkgs.config.permittedInsecurePackages = [
    "electron-39.8.10"
  ];

  fonts.packages = with pkgs; [
    # Hack patched with Nerd Font glyphs (powerline + icon Private Use Area
    # ranges) so terminals/starship/fastfetch render icons instead of tofu.
    nerd-fonts.hack
    # Catch-all icon fallback for any app whose font isn't Nerd-patched.
    nerd-fonts.symbols-only
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
  ];
}
