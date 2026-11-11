# Antigravity (agent hub) and Antigravity IDE pinned ahead of nixos-unstable.
# hub.nix / ide.nix are nixpkgs' derivations; only sources.json changes on
# update. Bump with `nix run .#update-antigravity`, then rebuild.
#
# Each pin applies only while it is newer than nixpkgs, so once nixpkgs
# catches up the overlay falls through to nixpkgs instead of downgrading.
# Drop this overlay if nixpkgs keeps up on its own.
final: prev:
let
  inherit (prev) lib;
  newer = ours: theirs: if lib.versionOlder theirs.version ours.version then ours else theirs;
in
{
  antigravity-hub = newer (prev.callPackage ./hub.nix { }) prev.antigravity-hub;
  antigravity-ide = newer (prev.callPackage ./ide.nix { }) prev.antigravity-ide;
  antigravity-ide-fhs = final.antigravity-ide.fhs;
  antigravity-ide-fhsWithPackages = final.antigravity-ide.fhsWithPackages;

  update-antigravity = prev.writeShellApplication {
    name = "update-antigravity";
    runtimeInputs = with prev; [
      curl
      jq
      coreutils
      nix
    ];
    text = builtins.readFile ./update.sh;
  };
}
