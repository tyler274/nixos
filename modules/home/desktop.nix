{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

{
  imports = [
    inputs.mini-diarium.homeModules.default
    ./bitwarden.nix
    ./halloy.nix
  ];

  bitwarden.enable = true;

  # Encrypted, local-first journaling app (packaged from the mini-diarium flake).
  programs.mini-diarium.enable = true;

  programs.firefox = {
    enable = true;
    nativeMessagingHosts = [ pkgs.kdePackages.plasma-browser-integration ];
    configPath = "${config.xdg.configHome}/mozilla/firefox";
    package = pkgs.firefox;
  };

  programs.thunderbird = {
    enable = true;
    package = pkgs.thunderbird-bin;
  };

  #programs.nheko.enable = true;

  home.packages = with pkgs; [
    signal-desktop
    discord
    fractal
    microsoft-edge
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
    cura-appimage
    orca-slicer

    vlc
    mpv
    spotify
    yt-dlp

    xivlauncher
    lutris
    chiaki
    protonup-qt

    libreoffice-qt-stable
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

    pocket-casts

    zed-editor
    obsidian
    #sublime4
    imhex
    # Bambu Studio's plate/model preview renders blank when glvnd
    # dispatches GLX/EGL to the NVIDIA vendor library, so force Mesa
    # (the machine's /run/opengl-driver carries both vendor JSONs).
    # Wrapping via symlinkJoin instead of overrideAttrs avoids
    # rebuilding the CUDA-overridden derivation; the desktop entry's
    # relative `Exec=bambu-studio` resolves to this wrapper via PATH.
    # See https://www.reddit.com/r/BambuLab/comments/1kx4v59/
    (symlinkJoin {
      name = "bambu-studio-mesa-glvnd";
      paths = [ bambu-studio ];
      nativeBuildInputs = [ makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/bambu-studio \
          --set __GLX_VENDOR_LIBRARY_NAME mesa \
          --set __EGL_VENDOR_LIBRARY_FILENAMES /run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json \
          --set MESA_LOADER_DRIVER_OVERRIDE zink \
          --set GALLIUM_DRIVER zink
      '';
    })
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
      # Lychee Slicer 7.6.2+ logs in via the browser and returns the session
      # through a lycheeslicer:// redirect; without this handler login never
      # completes (the nixpkgs desktop file registers no URL scheme).
      "x-scheme-handler/lycheeslicer" = [ "lycheeslicer.desktop" ];
    };
  };
  # Force-overwrite mimeapps.list on every activation so KDE's in-session
  # edits (which turn the symlink into a plain file) cannot block future
  # switches when the .hm-backup slot is already occupied.
  xdg.configFile."mimeapps.list".force = true;

  # The desktop file shipped by the nixpkgs lycheeslicer package
  # ("Lychee Slicer.desktop") lacks %u and the lycheeslicer:// scheme, so it
  # cannot receive the browser-login callback. Provide a corrected entry that
  # the mimeapps handler above points at.
  xdg.desktopEntries.lycheeslicer = {
    name = "Lychee Slicer";
    genericName = "Resin Slicer";
    comment = "All-in-one 3D slicer for Resin and Filament";
    exec = "lycheeslicer %u";
    terminal = false;
    categories = [ "Graphics" ];
    mimeType = [
      "model/stl"
      "x-scheme-handler/lycheeslicer"
    ];
  };
  # Shadow the package's own "Lychee Slicer.desktop" so the launcher only
  # shows the corrected entry above.
  xdg.desktopEntries."Lychee Slicer" = {
    name = "LycheeSlicer";
    noDisplay = true;
  };

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
