{ config, lib, ... }:

{
  # Apply the mold-wrapped linker to the same packages that go through ccache.
  # mold-wrapped is the NixOS-idiomatic wrapper: it carries the correct library
  # search paths so linking succeeds inside the Nix sandbox (plain `mold` does
  # not wire up library paths the way ld/lld wrappers do).
  #
  # Dotted attribute paths (e.g. kdePackages.qtwebengine) require nested
  # overlays and are skipped; they are uncommon linker bottlenecks anyway.
  nixpkgs.overlays = [
    (final: prev:
      let
        names = builtins.filter
          (n: !(lib.hasInfix "." n) && prev ? ${n})
          config.programs.ccache.packageNames;

        withMold = pkg: pkg.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ prev.mold-wrapped ];
          NIX_CFLAGS_LINK = toString (old.NIX_CFLAGS_LINK or "") + " -fuse-ld=mold";
        });
      in
        builtins.listToAttrs (map (n: { name = n; value = withMold prev.${n}; }) names)
    )
  ];
}
