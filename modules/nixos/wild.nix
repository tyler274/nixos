{
  config,
  lib,
  pkgs,
  ...
}:

let
  # GCC 15 rejects `-fuse-ld=wild` (only bfd/gold/lld/mold are named).
  # `-B` makes collect2 search this directory for `ld` without replacing
  # PATH's nix ld-wrapper. Absolute store path, so this is also the
  # build-time reference that keeps wild-ld alive.
  #
  # ld-prefix/ld is Wild behind nix's ld-wrapper, so `-L` becomes
  # DT_RUNPATH (needed for gcc's cc1 / libgmp, binutils `size` / libz,
  # and the rest of bootstrap).
  wildBflags = wildLd: " -B${wildLd}/ld-prefix";

  # Do not call `stdenv.override` on Cyrene: `hostPlatform.gcc.arch = znver5`
  # makes that reconstruct gcc with the stdenv we are defining.
  # Patch `mkDerivation` instead so every package — gcc, binutils, glibc,
  # the kernel, bootstrap stages — gets Wild without rebuilding the
  # compiler just to swap `ld`.
  injectWild =
    wildLd: stdenv:
    let
      oldMk = stdenv.mkDerivation;
      addWild =
        args:
        if args.dontUseWildLinker or false then
          args
        else
          let
            nbi = args.nativeBuildInputs or [ ];
            already = builtins.elem wildLd nbi;
            existing = toString (
              (args.env or { }).NIX_CFLAGS_LINK or (args.NIX_CFLAGS_LINK or "")
            );
          in
          # Drop a top-level NIX_CFLAGS_LINK so it cannot overlap `env`
          # (stdenv rejects that when structuredAttrs is on).
          (removeAttrs args [ "NIX_CFLAGS_LINK" ])
          // {
            nativeBuildInputs = if already then nbi else nbi ++ [ wildLd ];
            env = (args.env or { }) // {
              NIX_CFLAGS_LINK = if already then existing else existing + wildBflags wildLd;
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
    # packageNames entry gets `-B` as well as the stdenv swap.
    (
      final: prev:
      let
        names = builtins.filter (
          n: !(lib.hasInfix "." n) && prev ? ${n}
        ) config.programs.ccache.packageNames;

        withWild =
          pkg:
          pkg.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.wild-ld ];
            NIX_CFLAGS_LINK = toString (old.NIX_CFLAGS_LINK or "") + wildBflags final.wild-ld;
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
