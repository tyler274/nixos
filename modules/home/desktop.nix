{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

let
  liberaBitwarden = import ../lib/halloy-libera-bitwarden.nix { inherit pkgs lib; };
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
              password_command = "${liberaBitwarden.passwordScript}";
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

  # Halloy server settings (including password_command) are managed in Nix.
  # Refuse activation if config.toml was edited to point at another helper, and
  # make the file read-only so other local users cannot retarget it.
  home.activation.secureHalloyConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    config_dir="${config.xdg.configHome}/halloy"
    config_file="$config_dir/config.toml"
    expected_cmd='${liberaBitwarden.passwordScript}'

    run install -d -m 0700 "$config_dir"

    if [ -f "$config_file" ]; then
      if ! ${pkgs.gnugrep}/bin/grep -Fq "$expected_cmd" "$config_file"; then
        echo "error: $config_file password_command does not match the Nix store helper" >&2
        exit 1
      fi
      run chmod 0444 "$config_file"
    fi
  '';
}
