{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    firefox
    thunderbird
    signal-desktop
    discord
    (pkgs.writeShellApplication {
      name = "discord-wayland";
      text = "${pkgs.discord}/bin/discord --enable-features=WebRTCPipeWireCapturer --use-gl=desktop";
    })
    (pkgs.makeDesktopItem {
      name = "DiscordWayland";
      icon = "Discord";
      exec = "discord-wayland";
      desktopName = "DiscordWayland";
    })
    microsoft-edge
    (pkgs.writeShellApplication {
      name = "microsoft-edge-wayland";
      text = "${pkgs.microsoft-edge}/bin/microsoft-edge --enable-features=WebRTCPipeWireCapturer,UseOzonePlatform,WaylandWindowDecorations --ozone-platform=wayland";
    })
    (pkgs.makeDesktopItem {
      name = "MicrosoftEdgeWayland";
      exec = "microsoft-edge-wayland";
      desktopName = "MicrosoftEdgeWayland";
    })

    bitwarden-desktop
    (pkgs.writeShellApplication {
      name = "bitwarden-wayland";
      text = "${pkgs.bitwarden-desktop}/bin/bitwarden --use-gl=desktop";
    })
    (pkgs.makeDesktopItem {
      name = "BitwardenWayland";
      exec = "bitwarden-wayland";
      desktopName = "BitwardenWayland";
    })

    stable-pkgs.telegram-desktop

    gcc
    cmake
    gnumake
    pkg-config
    freetype
    llvmPackages_19.bintools
    mold
    rustup
    dotnet-sdk_9
    python312
    python312Packages.pip
    vscode

    nixd
    nix-output-monitor

    (appimage-run.override {
      extraPkgs = pkgs: [ nss swt webkitgtk_4_1 glib-networking ];
    })
    glib-networking

    blender
    krita
    cura
    obs-studio
    reaper

    vlc
    mpv
    spotify
    yt-dlp

    xivlauncher
    lutris
    chiaki
    protonup-qt

    libreoffice-qt
    kdePackages.ark
    qbittorrent

    kdePackages.ksshaskpass
    kdePackages.qtstyleplugin-kvantum
    kdePackages.yakuake

    opensnitch-ui
    metasploit
    matrix-conduit

    liquidctl

    wayland
    betterdiscordctl
    rpcs3
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
    };
  };
}
