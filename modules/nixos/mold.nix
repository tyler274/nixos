{ ... }:

{
  # Replace the default GNU ld with mold for all nixpkgs builds.
  # mold is a drop-in ld replacement that is significantly faster,
  # especially for large C++ projects (Chromium, LLVM, KDE, etc.).
  # Composes correctly with ccacheStdenv since mold only affects linking.
  nixpkgs.overlays = [
    (final: prev: {
      stdenv = prev.useMoldLinker prev.stdenv;
    })
  ];
}
