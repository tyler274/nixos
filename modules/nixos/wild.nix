{
  config,
  lib,
  pkgs,
  ...
}:

let
  # GCC 15 rejects `-fuse-ld=elyld` (only bfd/gold/lld/mold are named).
  # `-B` makes collect2 search this directory for `ld` without replacing
  # PATH's nix ld-wrapper. Absolute store path, so this is also the
  # build-time reference that keeps elyld-ld alive.
  #
  # ld-prefix/ld is ElyLD behind nix's ld-wrapper, so `-L` becomes
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
        let
          pname = args.pname or "";
          name = args.name or "";
          # Compiler / bintools wrappers are finalAttrs derivations. Their
          # `env` / `bintools` close over the wrapper being defined; adding
          # elyld-ld there loops outPath (wasm32 llvm-binutils-wrapper via
          # firefox → wasi-sysroot). Wrappers are shell scripts and do not
          # need ElyLD. gcc, binutils, glibc, kernel, bootstrap still get it.
          isWrapper =
            lib.hasInfix "wrapper" pname
            || lib.hasInfix "wrapper" name
            || (args ? isClang)
            || (args ? isGNU)
            || (args ? bintools && args ? libc);
        in
        if args.dontUseWildLinker or args.dontUseElyldLinker or false || isWrapper then
          args
        else
          let
            nbi = args.nativeBuildInputs or [ ];
          in
          args
          // {
            nativeBuildInputs = nbi ++ [ wildLd ];
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
  # Make ElyLD the stdenv linker. `pkgs.elyld` comes from overlays/wild.nix
  # (nested nixpkgs, system allocator so the Cyrene preload can see heap).
  #
  # Firefox's private LLVM stdenv and CUDA `backendStdenv` still pick
  # their own linker (lld / nvcc); same gap as hosts/cyrene/ccache.nix.
  nixpkgs.overlays = [
    # mkAfter: elyld-ld lives in overlays/wild.nix (flake overlays). Without
    # this, module sort can apply this wrap *before* that overlay, so
    # `prev.elyld-ld` is missing. `final.elyld-ld` is the fixpoint either way.
    (lib.mkAfter (
      final: prev: {
        # Temporarily no stdenv wrap — testing whether injectWild is the NMH loop.
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
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.elyld-ld ];
            NIX_CFLAGS_LINK = toString (old.NIX_CFLAGS_LINK or "") + wildBflags final.elyld-ld;
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

  # elyld-ld, not wrapBintoolsWith pkgs.elyld: the latter's bin/ld
  # collides with gcc in home-manager-path (and would shadow PATH ld).
  environment.systemPackages = [ pkgs.elyld-ld ];
}
