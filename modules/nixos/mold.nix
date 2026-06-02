{ ... }:

{
  # Use mold as the system linker for all nixpkgs builds.
  #
  # CC_LD / CXX_LD are build-time env vars (not stdenv constructor params),
  # so they must be injected via a setup hook rather than stdenv.override
  # args. The hook is placed in stdenv.extraBuildInputs so it is sourced
  # automatically for every derivation built with that stdenv.
  nixpkgs.overlays = [
    (final: prev:
      let
        moldHook = prev.makeSetupHook { name = "mold-linker-hook"; } (
          prev.writeText "mold-linker-setup-hook.sh" ''
            export CC_LD=mold
            export CXX_LD=mold
          ''
        );

        withMold = stdenv: stdenv.override (old: {
          extraBuildInputs = (old.extraBuildInputs or [ ]) ++ [ prev.mold moldHook ];
        });
      in {
        stdenv      = withMold prev.stdenv;
        clangStdenv = withMold prev.clangStdenv;
      })
  ];
}
