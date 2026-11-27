args@{
  config,
  lib,
  pkgs,
  ...
}:

# The from-source world rebuild: every package compiled with -march=znver5
# and linked with ElyLD (github:tyler274/ElyLD), with ccache as crash
# insurance for the multi-hour builds. Each piece changes derivation hashes,
# so nothing comes from cache.nixos.org while this is on.
#
# One switch for all of it. When enabled it also turns on, elsewhere:
#   - the core-package fix overlays in flake.nix (llvm, znver5, nodejs, ...);
#   - the per-package ccache wraps in ./ccache.nix.
#
# The resulting system only boots on Zen 5 (AVX-512 and newer ISA).
let
  cfg = config.cyrene.worldRebuild;

  # Plain config modules (no imports/options), applied only while enabled.
  gated = file: lib.mkIf cfg.enable (import file args);
in
{
  options.cyrene.worldRebuild.enable = lib.mkEnableOption "the znver5 + ElyLD from-source world rebuild";

  config = lib.mkMerge [
    (gated ../../modules/nixos/wild.nix)
    (gated ../../modules/nixos/rustc-elymalloc.nix)
    (gated ../../modules/nixos/ccache.nix)

    (lib.mkIf cfg.enable {
      # Target the Ryzen 9 9950X3D (Zen 5); overrides the plain x86_64-linux
      # mkDefault in hardware-configuration.nix. Needs the gccarch-znver5
      # system-feature (modules/nixos/common.nix).
      nixpkgs.hostPlatform = {
        system = "x86_64-linux";
        gcc.arch = "znver5";
        gcc.tune = "znver5";
      };

      nix.settings = {
        # The cachix substituters only serve standard-arch builds, so they
        # can never hit; each would still cost a narinfo query per
        # derivation. cache.nixos.org still serves the arch-independent
        # fixed-output sources.
        substituters = lib.mkForce [ "https://cache.nixos.org" ];
        # Remember misses for 24h so fix-and-rebuild loops don't re-query
        # thousands of known-missing paths.
        narinfo-cache-negative-ttl = 86400;
      };

      home-manager.users.luluco = {
        # Interactive Meson/CMake linker. GCC 15 rejects `-fuse-ld=elyld`, so
        # CC_LD stays empty and collect2 finds ElyLD through `-B`, the same
        # flag wild.nix gives system packages.
        home.sessionVariables = {
          CC_LD = lib.mkForce "";
          CXX_LD = lib.mkForce "";
          NIX_CFLAGS_LINK = "-B${pkgs.elyld-ld}/ld-prefix";
        };
        # PATH-safe ElyLD (`elyld` / `ld.elyld`); pkgs.elyld's bin/ld would
        # collide with gcc's ld in home-manager-path.
        home.packages = [ pkgs.elyld-ld ];
      };
    })
  ];
}
