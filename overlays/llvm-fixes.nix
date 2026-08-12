# LLVM 21's test suite includes llvm-exegesis/RISCV/rvv/filter.test,
# which is nondeterministic (random snippet generation sometimes fails
# to assign unique def/use registers) and known to flake on upstream
# buildbots. LLVM 22 fixed it by pinning the RNG seed
# (llvm/llvm-project#170014); until nixpkgs ships 22 as default, drop
# the test so from-source rebuilds don't die on a coin flip. The
# overrideScope makes clang/lld/etc. pick up the fixed libllvm.
#
# overrideScope returns a bare scope without the .override attribute
# that callPackage attached to the original llvmPackages_21, and
# build-mozilla-mach (firefox/thunderbird) calls llvmPackages.override
# to force lld for LTO. fixLlvmScope therefore re-attaches .override,
# wrapped so the re-instantiated scope gets the same test removal —
# firefox's LLVM variant is a separate derivation that runs the test
# suite again and would otherwise hit the same flake.
final: prev:
let
  dropFlakyTest = lFinal: lPrev: {
    libllvm = lPrev.libllvm.overrideAttrs (old: {
      # sourceRoot is the llvm/ subdir of the monorepo, hence the
      # test/ (not llvm/test/) prefix.
      postPatch = (old.postPatch or "") + ''
        rm -f test/tools/llvm-exegesis/RISCV/rvv/filter.test
      '';
    });
  };
  fixLlvmScope = scope:
    scope.overrideScope dropFlakyTest
    // final.lib.optionalAttrs (scope ? override) {
      override = args: fixLlvmScope (scope.override args);
    };
in
{
  llvmPackages_21 = fixLlvmScope prev.llvmPackages_21;
}
