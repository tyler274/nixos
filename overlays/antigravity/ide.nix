# nixpkgs' pkgs/by-name/an/antigravity-ide/package.nix (Linux only), with the
# version and sources read from sources.json.
{
  lib,
  stdenv,
  buildVscode,
  fetchurl,
  writeShellScript,
  coreutils,
  commandLineArgs ? "",
  useVSCodeRipgrep ? false,
}:

let
  pin = (lib.importJSON ./sources.json).ide;
  system = stdenv.hostPlatform.system;
  source = pin.sources.${system} or (throw "antigravity-ide: unsupported system ${system}");
in
buildVscode {
  inherit commandLineArgs useVSCodeRipgrep;
  inherit (pin) version vscodeVersion;
  pname = "antigravity-ide";

  executableName = "antigravity-ide";
  longName = "Antigravity IDE";
  shortName = "Antigravity IDE";
  libraryName = "antigravity-ide";
  iconName = "antigravity-ide";

  src = fetchurl { inherit (source) url hash; };

  sourceRoot = "Antigravity IDE";

  tests = { };
  updateScript = null;

  # When running inside an FHS environment, try linking Google Chrome or Chromium
  # to the hardcoded Playwright search path: /opt/google/chrome/chrome
  customizeFHSEnv =
    args:
    args
    // {
      extraBwrapArgs = (args.extraBwrapArgs or [ ]) ++ [ "--tmpfs /opt/google/chrome" ];
      extraBuildCommands = (args.extraBuildCommands or "") + ''
        mkdir -p "$out/opt/google/chrome"
      '';
      runScript = writeShellScript "antigravity-ide-wrapper" ''
        for candidate in google-chrome-stable google-chrome chromium-browser chromium; do
          if target=$(command -v "$candidate"); then
            ${coreutils}/bin/ln -sf "$target" /opt/google/chrome/chrome
            break
          fi
        done
        exec ${args.runScript} "$@"
      '';
    };

  meta = {
    mainProgram = "antigravity-ide";
    description = "Agentic development platform, evolving the IDE into the agent-first era";
    homepage = "https://antigravity.google/product/antigravity-ide";
    downloadPage = "https://antigravity.google/download#antigravity-ide";
    changelog = "https://antigravity.google/changelog";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = lib.attrNames pin.sources;
  };
}
