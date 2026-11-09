# Cursor pinned ahead of nixos-unstable. package.nix is nixpkgs'
# pkgs/by-name/co/code-cursor/package.nix; only sources.json changes on
# update. Bump with `nix run .#update-cursor`, then rebuild. Drop this overlay
# if nixpkgs keeps up on its own.
final: prev: {
  code-cursor = prev.callPackage ./package.nix { };
  code-cursor-fhs = final.code-cursor.fhs;
  code-cursor-fhsWithPackages = final.code-cursor.fhsWithPackages;

  update-cursor = prev.writeShellApplication {
    name = "update-cursor";
    runtimeInputs = with prev; [
      curl
      jq
      coreutils
      nix
      _7zz
    ];
    text = builtins.readFile ./update.sh;
  };
}
