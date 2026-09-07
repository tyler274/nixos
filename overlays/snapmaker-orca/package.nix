# Snapmaker Orca Slicer (fork of OrcaSlicer with Snapmaker machine
# profiles, color mixing, etc.). Upstream does not publish a Nix build;
# wrap the official Ubuntu 24.04 x86_64 AppImage from GitHub releases.
#
# Built via cacheablePkgs in overlay.nix so the FHS env's gtk/webkit stack
# comes from Hydra instead of a znver5 from-source rebuild.
{
  lib,
  appimageTools,
  fetchurl,
  makeWrapper,
}:

let
  pname = "snapmaker-orca";
  version = "2.3.6";

  src = fetchurl {
    url = "https://github.com/Snapmaker/OrcaSlicer/releases/download/V${version}/Snapmaker_Orca_Linux_AppImage_Ubuntu2404_V${version}.AppImage";
    hash = "sha256-HNFgbTvFgsk3umfDKJ2o03Obw4CSum15KWi/KLLzN9I=";
  };

  appimageContents = appimageTools.extract { inherit pname version src; };
in
# wrapType2's FHS /etc does not propagate ld-nix.so.preload, so mimalloc
# is already out of the picture (no extra bwrap bind needed).
appimageTools.wrapType2 {
  inherit pname version src;

  extraPkgs =
    pkgs: with pkgs; [
      webkitgtk_4_1
      gst_all_1.gstreamer
      gst_all_1.gst-plugins-base
      gst_all_1.gst-plugins-good
      gst_all_1.gst-plugins-bad
      libsecret
      libGL
      libglvnd
    ];

  nativeBuildInputs = [ makeWrapper ];

  extraInstallCommands = ''
    install -Dm644 ${appimageContents}/io.github.Snapmaker.Snapmaker_Orca.desktop \
      $out/share/applications/${pname}.desktop
    chmod u+w $out/share/applications/${pname}.desktop
    sed -i \
      -e 's|^Exec=.*|Exec=${pname} %F|' \
      -e 's|^Icon=.*|Icon=${pname}|' \
      $out/share/applications/${pname}.desktop
    grep -q '^StartupWMClass=' $out/share/applications/${pname}.desktop \
      || echo 'StartupWMClass=OrcaSlicer' >> $out/share/applications/${pname}.desktop

    install -Dm444 ${appimageContents}/Snapmaker_Orca.png \
      $out/share/icons/hicolor/256x256/apps/${pname}.png
    if [ -f ${appimageContents}/usr/share/icons/hicolor/192x192/apps/Snapmaker_Orca.png ]; then
      install -Dm444 ${appimageContents}/usr/share/icons/hicolor/192x192/apps/Snapmaker_Orca.png \
        $out/share/icons/hicolor/192x192/apps/${pname}.png
    fi

    wrapProgram $out/bin/${pname} \
      --set WEBKIT_DISABLE_COMPOSITING_MODE 1 \
      --set WEBKIT_DISABLE_DMABUF_RENDERER 1 \
      --set __GLX_VENDOR_LIBRARY_NAME mesa \
      --set __EGL_VENDOR_LIBRARY_FILENAMES /run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json \
      --set MESA_LOADER_DRIVER_OVERRIDE zink \
      --set GALLIUM_DRIVER zink
  '';

  passthru = {
    inherit src appimageContents;
  };

  meta = {
    description = "Snapmaker fork of Orca Slicer for Snapmaker 3D printers";
    homepage = "https://github.com/Snapmaker/OrcaSlicer";
    changelog = "https://github.com/Snapmaker/OrcaSlicer/releases/tag/V${version}";
    license = lib.licenses.agpl3Only;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = pname;
  };
}
