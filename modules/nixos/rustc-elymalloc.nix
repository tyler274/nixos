{ lib, inputs, ... }:

{
  # mkAfter: rustc wrap needs the elymalloc overlay (flake.nix) already in
  # `prev` so `callPackage rust/package.nix` can see llvm/stdenv, and must
  # run after znver5/ElyLD overlays so this rustc is the one rustPlatform
  # closes over.
  nixpkgs.overlays = lib.mkAfter [
    (import ../../overlays/rustc-elymalloc.nix inputs)
  ];
}
