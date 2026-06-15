{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

let
  # Bitwarden login item name for the Libera NickServ password.
  liberaBitwardenItem = "libera.chat";

  halloyLiberaBitwardenPassword = pkgs.writeShellScript "halloy-libera-bitwarden-password" ''
    set -euo pipefail

    export PATH=${lib.makeBinPath [ pkgs.bitwarden-cli pkgs.jq ]}:''${PATH:-}

    item=${lib.escapeShellArg liberaBitwardenItem}
    status_json=$(${pkgs.bitwarden-cli}/bin/bw status --raw 2>/dev/null || echo '{"status":"unauthenticated"}')
    vault_status=$(${pkgs.jq}/bin/jq -r '.status // "unauthenticated"' <<< "$status_json")

    if [[ "$vault_status" != "unlocked" ]]; then
      exit 1
    fi

    ${pkgs.bitwarden-cli}/bin/bw get password "$item" --nointeraction 2>/dev/null | tr -d '\n'
  '';
in

{
  imports = [ inputs.mini-diarium.homeModules.default ];

  # Encrypted, local-first journaling app (packaged from the mini-diarium flake).
  programs.mini-diarium.enable = true;

  programs.firefox = {
    enable = true;
    nativeMessagingHosts = [ pkgs.kdePackages.plasma-browser-integration ];
    configPath = "${config.xdg.configHome}/mozilla/firefox";
    package = pkgs.firefox-bin;
  };

  programs.thunderbird = {
    enable = true;
    package = pkgs.thunderbird-bin;
  };

  programs.halloy = {
    enable = true;
    settings = {
      servers = {
        libera = {
          nickname = config.home.username;
          server = "irc.libera.chat";
          use_tls = true;
          channels = [ "#gssapi" ];
          sasl = {
            plain = {
              # Bitwarden item "libera.chat"; SASL username is the registered IRC nick.
              username = config.home.username;
              # Fetched via bitwarden-cli when the vault is already unlocked.
              # Requires a one-time `bw login`; no unlock prompts are shown.
              password_command = "${halloyLiberaBitwardenPassword}";
              disconnect_on_failure = true;
            };
          };
        };
      };
    };
  };

  #programs.nheko.enable = true;

  home.packages = with pkgs; [
    signal-desktop
    discord
    fractal
    microsoft-edge
    bitwarden-desktop
    bitwarden-cli
    stable-pkgs.telegram-desktop

    gcc
    cmake
    gnumake
    pkg-config
    freetype
    mold
    rustup
    dotnet-sdk_10

    nix-output-monitor

    #(appimage-run.override {
    #  extraPkgs = pkgs: [ nss swt webkitgtk_4_1 glib-networking ];
    #})
    glib-networking

    blender
    krita
    # Unmaintained and removed from nixpkgs
    #stable-pkgs.cura
    obs-studio
    reaper
    lycheeslicer

    vlc
    mpv
    spotify
    yt-dlp

    xivlauncher
    lutris
    chiaki
    protonup-qt

    libreoffice-qt-fresh
    # Not available on x86_64-linux wow
    # libreoffice-bin
    kdePackages.ark
    qbittorrent

    kdePackages.ksshaskpass
    kdePackages.qtstyleplugin-kvantum
    kdePackages.yakuake
    kdePackages.plasma-browser-integration
    kdePackages.filelight

    opensnitch-ui
    metasploit
    armitage
    matrix-conduit

    liquidctl

    wayland
    betterdiscordctl
    #rpcs3
    shadps4
    shadps4-qtlauncher

    androidsdk
    android-studio-full
    android-tools

    zed-editor
    #sublime4
    imhex
  ];

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = [ "firefox.desktop" ];
      "x-scheme-handler/http" = [ "firefox.desktop" ];
      "x-scheme-handler/https" = [ "firefox.desktop" ];
      "application/pdf" = [ "firefox.desktop" ];
      "video/mp4" = [ "mpv.desktop" ];
      "video/mkv" = [ "mpv.desktop" ];
      "audio/mpeg" = [ "mpv.desktop" ];
      "image/png" = [ "org.kde.gwenview.desktop" ];
      "image/jpeg" = [ "org.kde.gwenview.desktop" ];
      # Application-registered URI schemes — kept here so HM owns the full
      # file and KDE additions do not accumulate between rebuilds.
      "x-scheme-handler/capacities" = [ "capacities.desktop" ];
      "x-scheme-handler/bitwarden" = [ "bitwarden.desktop" ];
    };
  };
  # Force-overwrite mimeapps.list on every activation so KDE's in-session
  # edits (which turn the symlink into a plain file) cannot block future
  # switches when the .hm-backup slot is already occupied.
  xdg.configFile."mimeapps.list".force = true;

  # Android development: pin the AVD home so avdmanager and the emulator
  # always agree on where virtual devices live.  Without this the emulator
  # searches $HOME/.android/avd but avdmanager may write to a different path,
  # causing "Unknown AVD name" errors at boot time.
  # TODO: Double check these are correct.
  home.sessionVariables.ANDROID_AVD_HOME = "${config.home.homeDirectory}/.android/avd";

  home.activation.createAndroidAvdDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p "${config.home.homeDirectory}/.android/avd"
  '';
}
