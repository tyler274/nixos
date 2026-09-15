# Local ElyLD linker, built in a *nested* nixpkgs so Cyrene can swap stdenv's
# linker without: stdenv -> elyld -> rustc/mimalloc -> stdenv.
#
# Plain x86_64-linux, not Cyrene's znver5 hostPlatform: a nested znver5
# stdenv would rebuild gcc/glibc from source (cache.nixos.org has no
# znver5 nars). ElyLD is a build tool; it does not need -march=znver5.
#
# Allocator: ElyLD's default cargo `mimalloc` feature embeds Microsoft's C
# mimalloc via the mimalloc-rs *crate*. That bypasses `malloc()`, so the
# Cyrene preload would never see ElyLD's heap. Whole-archive of the rewrite
# `.a` into this Rust binary also duplicates `compiler_builtins` and leaks
# into crate build scripts. So we disable the C crate and keep the System
# allocator: on the live host `/etc/ld-nix.so.preload` intercepts `malloc`
# (the rewrite); in the Nix sandbox there is no preload and glibc malloc
# is used.
#
# Do not use `inputs.wild.overlays.default`: that overlay takes
# `pkgs = final` (the stdenv cycle) and its fileset is `gitTracked`
# (fails on a flake input with no `.git`).
inputs: final: prev:
let
  inherit (prev) lib;

  pkgsForWild = import inputs.nixpkgs {
    inherit (prev) config;
    system = prev.stdenv.hostPlatform.system;
  };

  craneLib = import inputs.wild.inputs.crane { pkgs = pkgsForWild; };

  cargoToml = builtins.fromTOML (builtins.readFile "${inputs.wild}/Cargo.toml");

  commonArgs = {
    pname = "elyld-unwrapped";
    inherit (cargoToml.workspace.package) version;
    src = inputs.wild;
    strictDeps = true;
    cargoExtraArgs = "--offline --no-default-features --features fork,plugins,zstd";
    nativeBuildInputs = [ pkgsForWild.pkg-config ];
    buildInputs = [ pkgsForWild.zstd ];
    env.ZSTD_SYS_USE_PKG_CONFIG = "1";
  };

  elyldUnwrapped =
    lib.throwIfNot (lib.versionAtLeast pkgsForWild.rustc.version "1.97.1")
      "ElyLD requires at least Rust 1.97.1, this instance of nixpkgs has Rust ${pkgsForWild.rustc.version}"
      craneLib.buildPackage
      (
        commonArgs
        // {
          cargoArtifacts = craneLib.buildDepsOnly commonArgs;
          cargoBuildCommand = "cargo build --profile release -p elyld";
          doCheck = false;
          doInstallCheck = true;
          nativeInstallCheckInputs = [ pkgsForWild.versionCheckHook ];
          versionCheckProgramArg = "--version";
          meta = {
            description = "A very fast linker for Linux";
            homepage = "https://github.com/tyler274/ElyLD";
            license = [
              lib.licenses.asl20
              lib.licenses.mit
            ];
            mainProgram = "elyld";
            platforms = lib.platforms.linux;
          };
        }
      );

  # nixpkgs `wild` bakes `buildPackages.wild-unwrapped` into extraBuildCommands
  # at eval time, so overlaying only the unwrapped attr leaves the wrapper
  # pointing at nixpkgs' binary. Re-wrap against this tree, with the nested
  # pkgs' wrapBintoolsWith (its stdenvNoCC is not the ElyLD stdenv).
  ldWrapper = "${pkgsForWild.path}/pkgs/build-support/bintools-wrapper/ld-wrapper.sh";
  targetPrefix = pkgsForWild.stdenv.cc.bintools.targetPrefix;

  elyldWrapped = pkgsForWild.wrapBintoolsWith {
    bintools = elyldUnwrapped;
    extraBuildCommands = ''
      wrap elyld ${ldWrapper} ${lib.getExe elyldUnwrapped}
      wrap ld.elyld ${ldWrapper} ${lib.getExe elyldUnwrapped}
      wrap ${targetPrefix}ld.elyld ${ldWrapper} ${lib.getExe elyldUnwrapped}
      wrap ${targetPrefix}ld ${ldWrapper} ${lib.getExe elyldUnwrapped}
    '';
  };

  # Injection helper for stdenv mkDerivation. The full wrap above cannot
  # go in every nativeBuildInputs: its setup hook carries a libc and
  # loops Cyrene's bintools-wrapper.
  #
  # `bin/` has unwrapped `elyld` / `ld.elyld` for PATH lookups (clang,
  # meson, rustc). `ld` stays out of `bin/` so PATH's nix ld-wrapper is
  # not shadowed.
  #
  # `ld-prefix/ld` is the *wrapped* ElyLD: nix's ld-wrapper scans `-L`
  # and emits DT_RUNPATH, then execs ElyLD. Unwrapped ElyLD here is what
  # dropped libgmp from gcc's cc1 and libz from binutils `size`. GCC 15
  # has no `-fuse-ld=elyld`; collect2 honours `-B` and looks for `ld`.
  elyldLd = pkgsForWild.runCommand "elyld-ld" { } ''
    mkdir -p $out/bin $out/ld-prefix
    ln -s ${lib.getExe elyldUnwrapped} $out/bin/elyld
    ln -s ${lib.getExe elyldUnwrapped} $out/bin/ld.elyld
    ln -s ${elyldWrapped}/bin/${targetPrefix}ld $out/ld-prefix/ld
    ln -s ${elyldWrapped}/bin/${targetPrefix}ld.elyld $out/ld-prefix/ld.elyld
  '';
in
{
  elyld-unwrapped = elyldUnwrapped;
  elyld = elyldWrapped;
  elyld-ld = elyldLd;

  # Keep the previous attr names so Cyrene's inject overlay and host
  # sessionVariables keep working without a full rebuild this change.
  wild-unwrapped = elyldUnwrapped;
  wild = elyldWrapped;
  wild-ld = elyldLd;
}
