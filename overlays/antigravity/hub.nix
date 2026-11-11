# nixpkgs' pkgs/by-name/an/antigravity-hub/package.nix (Linux only), with the
# version, build ID and hashes read from sources.json.
{
  lib,
  stdenv,
  fetchurl,
  alsa-lib,
  asar,
  at-spi2-atk,
  at-spi2-core,
  atk,
  autoPatchelfHook,
  cairo,
  copyDesktopItems,
  cups,
  dbus,
  expat,
  glib,
  gsettings-desktop-schemas,
  gtk3,
  libGL,
  libgbm,
  libnotify,
  libpulseaudio,
  libsecret,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  makeDesktopItem,
  makeShellWrapper,
  nspr,
  nss,
  pango,
  pipewire,
  systemdLibs,
  wrapGAppsHook3,
}:

let
  pin = (lib.importJSON ./sources.json).hub;
  platforms = {
    x86_64-linux = "linux-x64";
    aarch64-linux = "linux-arm";
  };
  system = stdenv.hostPlatform.system;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "antigravity-hub";
  inherit (pin) version;

  src = fetchurl {
    url = "https://storage.googleapis.com/antigravity-public/antigravity-hub/${finalAttrs.version}-${pin.buildId}/${
      platforms.${system} or (throw "antigravity-hub: unsupported system ${system}")
    }/Antigravity.tar.gz";
    hash = pin.hashes.${system};
  };

  __structuredAttrs = true;
  strictDeps = true;

  nativeBuildInputs = [
    asar
    autoPatchelfHook
    copyDesktopItems
    makeShellWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    glib
    gsettings-desktop-schemas
    gtk3
    libgbm
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    nspr
    nss
    pango
    systemdLibs
  ];

  # Loaded with dlopen() by the main binary, so autoPatchelfHook cannot discover them.
  runtimeDependencies = map lib.getLib [
    libnotify
    libpulseaudio
    libsecret
    pipewire
  ];
  # The bundled ANGLE libraries (libEGL.so, libGLESv2.so) dlopen() the system GL
  # libraries. runtimeDependencies only applies to executables, so extend the
  # RUNPATH of every patched ELF file instead.
  appendRunpaths = [ "${lib.getLib libGL}/lib" ];

  # The wrapper is created in postFixup to add the Wayland flags.
  dontWrapGApps = true;

  desktopItems = [
    (makeDesktopItem {
      name = "antigravity-hub";
      desktopName = "Antigravity";
      comment = "Manage multiple autonomous agents across independent projects";
      exec = "antigravity %U";
      icon = "antigravity";
      categories = [ "Development" ];
      mimeTypes = [ "x-scheme-handler/antigravity" ];
      startupWMClass = "antigravity";
    })
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/antigravity
    cp -r . $out/share/antigravity

    asar extract-file resources/app.asar icon.png
    install -Dm644 icon.png $out/share/icons/hicolor/512x512/apps/antigravity.png

    runHook postInstall
  '';

  # wrapGAppsHook3 provides makeBinaryWrapper, which cannot expand the shell
  # variables in --add-flags, hence makeShellWrapper.
  postFixup = ''
    makeShellWrapper $out/share/antigravity/antigravity $out/bin/antigravity \
      "''${gappsWrapperArgs[@]}" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations}}"
  '';

  meta = {
    description = "Desktop environment for managing multiple autonomous agents across independent projects";
    homepage = "https://antigravity.google";
    changelog = "https://antigravity.google/changelog";
    downloadPage = "https://antigravity.google/download";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = lib.attrNames platforms;
    mainProgram = "antigravity";
  };
})
