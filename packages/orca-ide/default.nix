{
  lib,
  appimageTools,
  fetchurl,
  makeWrapper,
}:
let
  pname = "orca-ide";
  version = "1.4.251";
  src = fetchurl {
    url = "https://github.com/stablyai/orca/releases/download/v${version}/orca-linux.AppImage";
    hash = "sha256-JmH/gvtT/VL4cXEFlR3zt4x68CYicw/FysFT6zgQDjw=";
  };
  appimageContents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;
  extraPkgs = pkgs: [ pkgs.libsecret pkgs.xorg-server pkgs.xauth ];
  nativeBuildInputs = [ makeWrapper ];
  extraInstallCommands = ''
    mv $out/bin/orca-ide $out/bin/orca-desktop
    makeWrapper $out/bin/orca-desktop $out/bin/orca-ide \
      --set ELECTRON_RUN_AS_NODE 1 \
      --add-flags ${appimageContents}/resources/app.asar.unpacked/out/cli/index.js
    install -Dm644 ${appimageContents}/orca-ide.desktop $out/share/applications/orca-ide.desktop
    substituteInPlace $out/share/applications/orca-ide.desktop \
      --replace-fail 'Exec=AppRun' 'Exec=orca-desktop'
    install -Dm644 ${appimageContents}/orca-ide.png $out/share/icons/hicolor/512x512/apps/orca-ide.png
  '';
  passthru = { inherit appimageContents; };
  meta = {
    description = "Orca coding agent runtime and desktop client";
    homepage = "https://github.com/stablyai/orca";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = pname;
  };
}
