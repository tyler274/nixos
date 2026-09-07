# Snapmaker Orca Slicer AppImage. Instantiated against uncustomized
# nixpkgs so the wrapType2 FHS env hits Hydra instead of a znver5
# world rebuild. Drop this overlay if nixpkgs ever ships the fork.
final: prev:
let
  cacheablePkgs = import prev.path {
    system = prev.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
{
  snapmaker-orca = cacheablePkgs.callPackage ./package.nix { };

  snapmaker-orca-update = cacheablePkgs.writeShellApplication {
    name = "snapmaker-orca-update";
    runtimeInputs = with cacheablePkgs; [
      curl
      jq
      nix
      coreutils
      gnused
      gawk
      gnugrep
    ];
    text = builtins.readFile ./update.sh;
  };
}
