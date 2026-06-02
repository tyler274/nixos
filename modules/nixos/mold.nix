{ ... }:

{
  # Replace GNU ld / LLVM lld with mold for all nixpkgs builds.
  #
  # CC_LD / CXX_LD tell GCC/Clang (>= 12) to invoke mold instead of their
  # default linker. mold is added to extraBuildInputs so it is on PATH.
  # We apply this to both the default GCC stdenv and clangStdenv rather than
  # calling useMoldLinker, which has a brittle stdenv.cc.isClang check that
  # breaks under stdenv compositions (e.g. ccache + mold).
  nixpkgs.overlays = [
    (final: prev:
      let
        withMold = stdenv: stdenv.override (old: {
          extraBuildInputs = (old.extraBuildInputs or [ ]) ++ [ prev.mold ];
          CC_LD = "mold";
          CXX_LD = "mold";
        });
      in {
        stdenv      = withMold prev.stdenv;
        clangStdenv = withMold prev.clangStdenv;
      })
  ];
}
