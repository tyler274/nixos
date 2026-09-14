# Local Wild linker, built in a *nested* nixpkgs so Cyrene can swap stdenv's
# linker without: stdenv -> wild -> rustc/mimalloc -> stdenv.
#
# Plain x86_64-linux, not Cyrene's znver5 hostPlatform: a nested znver5
# stdenv would rebuild gcc/glibc from source (cache.nixos.org has no
# znver5 nars). Wild is a build tool; it does not need -march=znver5.
#
# Allocator: Wild's default cargo `mimalloc` feature embeds Microsoft's C
# mimalloc via the mimalloc-rs *crate*. That bypasses `malloc()`, so the
# Cyrene preload would never see Wild's heap. Whole-archive of the rewrite
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
    pname = "wild-unwrapped";
    inherit (cargoToml.workspace.package) version;
    src = inputs.wild;
    strictDeps = true;
    cargoExtraArgs = "--offline --no-default-features --features fork,plugins,zstd";
    nativeBuildInputs = [ pkgsForWild.pkg-config ];
    buildInputs = [ pkgsForWild.zstd ];
    env.ZSTD_SYS_USE_PKG_CONFIG = "1";
  };

  wildUnwrapped =
    lib.throwIfNot (lib.versionAtLeast pkgsForWild.rustc.version "1.97.1")
      "Wild requires at least Rust 1.97.1, this instance of nixpkgs has Rust ${pkgsForWild.rustc.version}"
      craneLib.buildPackage
      (
        commonArgs
        // {
          cargoArtifacts = craneLib.buildDepsOnly commonArgs;
          cargoBuildCommand = "cargo build --profile release -p wild-linker";
          doCheck = false;
          doInstallCheck = true;
          nativeInstallCheckInputs = [ pkgsForWild.versionCheckHook ];
          versionCheckProgramArg = "--version";
          meta = {
            description = "A very fast linker for Linux";
            homepage = "https://github.com/wild-linker/wild";
            license = [
              lib.licenses.asl20
              lib.licenses.mit
            ];
            mainProgram = "wild";
            platforms = lib.platforms.linux;
          };
        }
      );

  # nixpkgs `wild` bakes `buildPackages.wild-unwrapped` into extraBuildCommands
  # at eval time, so overlaying only wild-unwrapped leaves the wrapper pointing
  # at nixpkgs' binary. Re-wrap against this tree, with the nested pkgs'
  # wrapBintoolsWith (its stdenvNoCC is not the Wild stdenv).
  ldWrapper = "${pkgsForWild.path}/pkgs/build-support/bintools-wrapper/ld-wrapper.sh";
  targetPrefix = pkgsForWild.stdenv.cc.bintools.targetPrefix;
in
{
  wild-unwrapped = wildUnwrapped;
  wild = pkgsForWild.wrapBintoolsWith {
    bintools = wildUnwrapped;
    extraBuildCommands = ''
      wrap wild ${ldWrapper} ${lib.getExe wildUnwrapped}
      wrap ld.wild ${ldWrapper} ${lib.getExe wildUnwrapped}
      wrap ${targetPrefix}ld.wild ${ldWrapper} ${lib.getExe wildUnwrapped}
      wrap ${targetPrefix}ld ${ldWrapper} ${lib.getExe wildUnwrapped}
    '';
  };

  # Unwrapped `ld.wild` on PATH for stdenv mkDerivation injection. The
  # full bintools wrap above cannot go in every nativeBuildInputs: it
  # carries a libc and loops Cyrene's bintools-wrapper.
  wild-ld = pkgsForWild.runCommand "wild-ld" { } ''
    mkdir -p $out/bin
    ln -s ${lib.getExe wildUnwrapped} $out/bin/wild
    ln -s ${lib.getExe wildUnwrapped} $out/bin/ld.wild
  '';
}
