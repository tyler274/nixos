{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Do not call `stdenv.override` on Cyrene: `hostPlatform.gcc.arch = znver5`
  # makes that reconstruct gcc with the stdenv we are defining.
  # Patch `mkDerivation` instead so every package gets Wild on PATH and
  # `-fuse-ld=wild`, without rebuilding the compiler.
  injectWild =
    wildLd: stdenv:
    let
      oldMk = stdenv.mkDerivation;
      addWild =
        args:
        args
        // {
          nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [ wildLd ];
          env = (args.env or { }) // {
            NIX_CFLAGS_LINK =
              toString ((args.env or { }).NIX_CFLAGS_LINK or (args.NIX_CFLAGS_LINK or "")) + " -fuse-ld=wild";
          };
        };
    in
    stdenv
    // {
      # mkDerivation accepts either an attrset or `finalAttrs: attrset`.
      mkDerivation =
        args: oldMk (if lib.isFunction args then (finalAttrs: addWild (args finalAttrs)) else addWild args);
    };
in
{
  # Make Wild the stdenv linker. `pkgs.wild` comes from overlays/wild.nix
  # (nested nixpkgs, statically linked to the Rust mimalloc rewrite).
  #
  # Firefox's private LLVM stdenv and CUDA `backendStdenv` still pick
  # their own linker (lld / nvcc); same gap as hosts/cyrene/ccache.nix.
  nixpkgs.overlays = [
    # mkAfter: wild-ld lives in overlays/wild.nix (flake overlays). Without
    # this, module sort can apply this wrap *before* that overlay, so
    # `prev.wild-ld` is missing. `final.wild-ld` is the fixpoint either way.
    (lib.mkAfter (
      final: prev: {
        stdenv = injectWild final.wild-ld prev.stdenv;
        clangStdenv = injectWild final.wild-ld prev.clangStdenv;
      }
    ))
    # Same ccache.packageNames hook mold.nix used. Cyrene's list is
    # commented out, so this is currently a no-op; keep it so a future
    # packageNames entry gets `-fuse-ld=wild` as well as the stdenv swap.
    (
      final: prev:
      let
        names = builtins.filter (
          n: !(lib.hasInfix "." n) && prev ? ${n}
        ) config.programs.ccache.packageNames;

        withWild =
          pkg:
          pkg.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ prev.wild-ld or prev.wild ];
            NIX_CFLAGS_LINK = toString (old.NIX_CFLAGS_LINK or "") + " -fuse-ld=wild";
          });
      in
      builtins.listToAttrs (
        map (n: {
          name = n;
          value = withWild prev.${n};
        }) names
      )
    )
  ];

  environment.systemPackages = [ pkgs.wild ];
}
