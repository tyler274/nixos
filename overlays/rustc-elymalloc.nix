# Cyrene rustc: ElyMalloc instead of jemalloc, statically, including programs.
#
# rustc does not use `#[global_allocator]` for jemalloc. `tikv-jemalloc-sys`
# feature `override_allocator_on_supported_platforms` statically overrides
# libc `malloc`/`free`, so `std::alloc::System` and C (LLVM) share one heap
# inside the rustc image. We do the same with ElyMalloc inside **libstd**:
# every bin/cdylib this rustc links embeds those symbols (no `DT_NEEDED`).
#
# Do not whole-archive `libmimalloc.a` (Rust `staticlib`): that duplicates
# `compiler_builtins` / `rust_eh_personality`. Copy `elymalloc-core` into
# rustc's `library/` as an rlib dep of std instead.
#
# `--set=rust.jemalloc=false` so jemalloc-sys does not also override malloc.
inputs: final: prev:
let
  inherit (prev) lib;
  # This overlay is applied to every package set, including rustc's
  # wasm32-wasip1 targetPackages. `overrideAttrs` on that rustc forces
  # `configureFlags` → wasm clang-wrapper → wasilibc → wasm-tools →
  # wasm rustc (Home Manager hits this via Firefox native-messaging-hosts).
  # Only wrap the native Linux rustc Cyrene actually runs.
  nativeLinux =
    (prev.stdenv.buildPlatform.system or "") == (prev.stdenv.hostPlatform.system or "")
    && (prev.stdenv.hostPlatform.system or "") == (prev.stdenv.targetPlatform.system or "")
    && (prev.stdenv.hostPlatform.isLinux or false);
in
if !nativeLinux then
  { }
else
  let
    elymallocCore = "${inputs.elymalloc}/rust/crates/elymalloc-core";
    mallocRs = ./rustc-elymalloc-malloc.rs;
  in
  {
  rustc-unwrapped = prev.rustc-unwrapped.overrideAttrs (old: {
    configureFlags = (old.configureFlags or [ ]) ++ [ "--set=rust.jemalloc=false" ];
    postPatch =
      (old.postPatch or "")
      + ''
        cp -a ${lib.escapeShellArg elymallocCore} library/elymalloc-core
        chmod -R u+w library/elymalloc-core
        rm -rf library/elymalloc-core/tests
        cat > library/elymalloc-core/Cargo.toml << 'EOF'
        [package]
        name = "elymalloc-core"
        version = "0.0.0"
        edition = "2021"
        license = "MIT"
        publish = false

        [lib]
        name = "elymalloc_core"
        test = false
        bench = false
        doctest = false

        [target.'cfg(unix)'.dependencies]
        libc = { version = "0.2.185", default-features = false, features = ["rustc-dep-of-std"] }
        EOF
        cp ${mallocRs} library/std/src/elymalloc_malloc.rs
        python3 - <<'PY'
        from pathlib import Path

        cargo = Path("library/std/Cargo.toml")
        extra = """

        [target.'cfg(unix)'.dependencies.elymalloc-core]
        path = "../elymalloc-core"
        """
        text = cargo.read_text()
        if "elymalloc-core" not in text:
            cargo.write_text(text + extra)

        lib_rs = Path("library/std/src/lib.rs")
        lib_text = lib_rs.read_text()
        needle = "pub mod alloc;\n"
        insert = needle + "#[cfg(unix)]\nmod elymalloc_malloc;\n"
        if "mod elymalloc_malloc" not in lib_text:
            if needle not in lib_text:
                raise SystemExit("std lib.rs: missing pub mod alloc")
            lib_rs.write_text(lib_text.replace(needle, insert, 1))

        alloc = Path("library/std/src/alloc.rs")
        a = alloc.read_text()
        marker = "pub mod __default_lib_allocator"
        idx = a.find(marker)
        if idx < 0:
            raise SystemExit("std alloc.rs: missing __default_lib_allocator")
        head, tail = a[:idx], a[idx:]
        old_use = "    use super::{GlobalAlloc, Layout, System};"
        new_use = """    use super::{GlobalAlloc, Layout, System};
    #[cfg(unix)]
    use elymalloc_core::ElyMalloc as DefaultAlloc;
    #[cfg(not(unix))]
    use super::System as DefaultAlloc;"""
        if old_use not in tail:
            raise SystemExit("std alloc.rs: missing __default_lib_allocator use")
        tail = tail.replace(old_use, new_use, 1)
        tail = tail.replace("System.alloc(", "DefaultAlloc.alloc(")
        tail = tail.replace("System.dealloc(", "DefaultAlloc.dealloc(")
        tail = tail.replace("System.realloc(", "DefaultAlloc.realloc(")
        tail = tail.replace("System.alloc_zeroed(", "DefaultAlloc.alloc_zeroed(")
        alloc.write_text(head + tail)
        PY
      '';
  });

  rustc = prev.wrapRustcWith {
    rustc-unwrapped = final.rustc-unwrapped;
  };

  rustPlatform = prev.makeRustPlatform {
    rustc = final.rustc;
    cargo = prev.cargo;
  };
}
