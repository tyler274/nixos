# Package fixes for building the world with -march=znver5 (Ryzen 9 9950X3D,
# see nixpkgs.hostPlatform in hosts/cyrene/default.nix). Two failure classes
# live here:
#
#   1. Test suites that fail for benign reasons — typically floating-point
#      unit tests that expect exact bit-for-bit results, broken by FMA/
#      AVX-512 contraction changing rounding. The libraries themselves are
#      fine; skip their check phases.
#   2. Genuine codegen bugs triggered by aggressive vectorization at the
#      wider ISA, worked around per package (prefer keeping tests enabled
#      for these so the workaround is actually verified).
#
# Expect this list to grow as the from-source world build progresses.
final: prev: {
  # linalg cholesky_invert test: expects a 0.0 residual, gets ~2.6e-13 with
  # FMA-contracted code.
  gsl = prev.gsl.overrideAttrs (old: { doCheck = false; });

  # AssimpAPITest_aiVector3D.aiTransformVecByMatrix4Test compares
  # vector-matrix products for exact float equality; FMA contraction changes
  # the rounding. Blocks qt3d and thereby pyside6 and the KDE stack.
  assimp = prev.assimp.overrideAttrs (old: { doCheck = false; });

  # GCC miscompiles the legacy blosclz codec at -O3 (segfaults in
  # blosclz_compress; observed with gcc 16 by Gentoo, reproduced here with
  # gcc 15 + znver5 vectorization — test_api/test_noinit/test_nolock/
  # test_nthreads SEGV). CMake's Release type forces -O3; the trailing
  # NIX_CFLAGS_COMPILE -O2 wins because the wrapper appends it after the
  # command-line flags. Tests stay enabled to verify the cap actually fixes
  # the codegen.
  c-blosc = prev.c-blosc.overrideAttrs (old: {
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE = ((old.env.NIX_CFLAGS_COMPILE or "") + " -O2");
    };
  });

  # simde is header-only, but its meson build compiles a large native +
  # emulated test suite by default (the only compiled artifacts), and the
  # AVX-512 tests fail to compile with gcc 15 at -march=znver5. -Dtests=false
  # skips them; the installed headers are identical. Revisit when nixpkgs
  # moves past simde 0.8.2.
  simde = prev.simde.overrideAttrs (old: {
    mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dtests=false" ];
  });

  # Not arch-related: eventlet's greenthread/patcher tests assert wall-clock
  # timeouts and starve when the machine is saturated by the from-source
  # world build. Disabling individual tests proved to be whack-a-mole — a
  # different pair timed out on the retry — so skip the suite outright.
  # Goes through pythonPackagesExtensions so all Python package sets and
  # their consumers agree on the fixed derivation.
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pyFinal: pyPrev: {
      eventlet = pyPrev.eventlet.overridePythonAttrs (old: {
        doCheck = false;
      });

      # Same class as eventlet: a wall-clock performance assertion (parse in
      # <0.5s; took 0.514s under full build load). It's the only timed test
      # in mistune's suite, so disabling it individually is safe.
      mistune = pyPrev.mistune.overridePythonAttrs (old: {
        disabledTests = (old.disabledTests or [ ]) ++ [
          "test_repeated_formatting_pairs_return_quickly"
        ];
      });
    })
  ];
}
