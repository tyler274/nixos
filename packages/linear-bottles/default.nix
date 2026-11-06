{
  lib,
  stdenvNoCC,
  fetchurl,
  bottles,
  python3,
  p7zip,
  icoextract,
  makeWrapper,
  writeText,
}:
let
  spec = {
    version = "1.32.8";
    installer = {
      url = "https://releases.linear.app/windows";
      hash = "sha256-RdqwQzepMx9bnyX6+3wVu5G85XHgeMyuS9b4lo4QNUo=";
    };
    runner = {
      name = "GE-Proton11-7-x86_64";
      url = "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-7/GE-Proton11-7-x86_64.tar.gz";
      sha256 = "c5448b76a230384e2d7bc6beb5ccb97bafb7e2c3b6c527cb03a1a546bbcb00a0";
    };
    bottle = "Linear";
    executable = "Linear.exe";
    parameters = {
      custom_dpi = 96;
      dxvk = true;
      vkd3d = true;
      use_runtime = false;
      use_steam_runtime = false;
      sync = "wine";
    };
    arguments = [ ];
  };
  installer = fetchurl {
    inherit (spec.installer) url hash;
    name = "Linear-Setup-${spec.version}.exe";
  };
  runner = stdenvNoCC.mkDerivation {
    pname = "linear-ge-proton";
    version = spec.runner.name;
    src = fetchurl { inherit (spec.runner) url sha256; };
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      mkdir -p "$out"
      cp -a . "$out/"
    '';
  };
  payload = stdenvNoCC.mkDerivation {
    pname = "linear-windows";
    inherit (spec) version;
    src = installer;
    nativeBuildInputs = [ p7zip icoextract ];
    dontUnpack = true;
    dontFixup = true;
    installPhase = ''
      runHook preInstall
      7z x "$src" '-oouter' '$PLUGINSDIR/app-64.7z'
      mkdir -p "$out/lib/linear" "$out/share/icons/hicolor/256x256/apps"
      7z x 'outer/$PLUGINSDIR/app-64.7z' "-o$out/lib/linear"
      icoextract "$out/lib/linear/Linear.exe" linear.ico
      ${python3.withPackages (p: [ p.pillow ])}/bin/python -c \
        'from PIL import Image; Image.open("linear.ico").save("'"$out"'/share/icons/hicolor/256x256/apps/linear-bottles.png")'
      runHook postInstall
    '';
  };
  bottlesPackage = bottles.override {
    extraPkgs = p: [ p.wineWow64Packages.stable ];
  };
  runtimeSpec = builtins.toJSON (spec // {
    runner = spec.runner // { path = "${runner}"; };
    executable = "${payload}/lib/linear/${spec.executable}";
    bottles = "${bottlesPackage}/bin/bottles-cli";
  });
  python = python3;
in
stdenvNoCC.mkDerivation {
  pname = "linear-bottles";
  inherit (spec) version;
  src = ./.;
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    ${python}/bin/python -m unittest -v test_launcher.py
  '';
  installPhase = ''
    mkdir -p "$out/bin" "$out/lib/linear-bottles" "$out/share"
    cp launcher.py "$out/lib/linear-bottles/launcher.py"
    cp ${writeText "linear-installation.json" runtimeSpec} "$out/lib/linear-bottles/installation.json"
    ln -s ${payload}/share/icons "$out/share/icons"
    makeWrapper ${python}/bin/python "$out/bin/linear-bottles" \
      --unset LD_LIBRARY_PATH --unset LD_PRELOAD \
      --add-flags "$out/lib/linear-bottles/launcher.py" \
      --add-flags "$out/lib/linear-bottles/installation.json" \
      --add-flags launch
    makeWrapper ${python}/bin/python "$out/bin/linear-bottles-setup" \
      --unset LD_LIBRARY_PATH --unset LD_PRELOAD \
      --add-flags "$out/lib/linear-bottles/launcher.py" \
      --add-flags "$out/lib/linear-bottles/installation.json" \
      --add-flags setup
  '';
  passthru = { inherit spec payload runner bottlesPackage; };
  meta = {
    description = "Official Windows Linear desktop app in a pinned Bottles environment";
    homepage = "https://linear.app";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "linear-bottles";
  };
}
