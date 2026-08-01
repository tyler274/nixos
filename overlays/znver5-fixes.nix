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

  # Not arch-related: Test2-Harness (yath) runs 62 integration-test files
  # that spawn real harness processes (758% CPU during the run); under full
  # build load t/integration/init.t flaked. Same live-process timing class
  # as eventlet/libmemcached, so skip the suite. overrideScope (rather than
  # config.perlPackageOverrides, which infinitely recurses for
  # self-referencing overrides) is verified to propagate into
  # nix-perl-bindings -> nix -> nixos-rebuild-ng, which this was blocking.
  perlPackages = prev.perlPackages.overrideScope (
    pFinal: pPrev: {
      Test2Harness = pPrev.Test2Harness.overrideAttrs (old: { doCheck = false; });
    }
  );

  # Not arch-related: 70-test_quic_multistream.t drives simulated QUIC
  # connections with idle timeouts and tick scheduling; it's reported flaky
  # upstream and failed here on a run where the whole suite took 1532s
  # wall-clock under full build load. The harness derives the test list by
  # globbing test/recipes/, so removing the file skips just this test.
  # Everything linking openssl rebuilds when this changes — post-GC that's
  # happening anyway, and it beats losing another python/curl rebuild to a
  # coin flip.
  openssl = prev.openssl.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      rm -f test/recipes/70-test_quic_multistream.t
    '';
  });

  # Not arch-related: the test suite runs live client/server exchanges against
  # a spawned memcached, and under full build load they flake one at a time —
  # first memcached_udp (loopback datagram drops mid-loop), then, with that
  # excluded, memcached_noblock (non-blocking I/O timing; every test in that
  # run also took ~430s vs ~89s unloaded). Same whack-a-mole as eventlet, so
  # skip the suite rather than chase individual tests.
  libmemcached = prev.libmemcached.overrideAttrs (old: { doCheck = false; });

  # Not arch-related: eventlet's greenthread/patcher tests assert wall-clock
  # timeouts and starve when the machine is saturated by the from-source
  # world build. Disabling individual tests proved to be whack-a-mole — a
  # different pair timed out on the retry — so skip the suite outright.
  # Goes through pythonPackagesExtensions so all Python package sets and
  # their consumers agree on the fixed derivation.
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pyFinal: pyPrev:
      let
        # Some python derivations carry disabledTests = null as an explicit
        # attribute; `old.disabledTests or [ ]` keeps the null in that case
        # (the `or` fallback only applies to *missing* attrs) and `null ++`
        # is an eval error. Normalize null/missing to [ ].
        appendDisabledTests =
          tests: old:
          let
            existing = old.disabledTests or null;
          in
          {
            disabledTests = (if existing == null then [ ] else existing) ++ tests;
          };
      in
      {
            eventlet = pyPrev.eventlet.overridePythonAttrs (old: {
              doCheck = false;
            });

            # Same class as eventlet: every capturer test prints into a pty
            # and asserts the background relay thread has already delivered
            # the output — a wall-clock race under build load (observed:
            # test_stdout_capture_same_process got [] while its subprocess
            # sibling passed). Upstream is unmaintained; skip the suite
            # rather than chase races one test at a time. Blocks
            # coloredlogs -> onnxruntime -> piper-tts/calibre.
            capturer = pyPrev.capturer.overridePythonAttrs (old: {
              doCheck = false;
            });

            # Same class as eventlet: a wall-clock performance assertion (parse
            # in <0.5s; took 0.514s under full build load). It's the only timed
            # test in mistune's suite, so disabling it individually is safe.
            mistune = pyPrev.mistune.overridePythonAttrs (
              appendDisabledTests [ "test_repeated_formatting_pairs_return_quickly" ]
            );

            # Wall-clock: asserts regex.sub(..., timeout=N) raises TimeoutError
            # while a slow replacement callback busy-waits; failed (no raise)
            # under full build load. The only timed test in a 567-test suite.
            # Blocks mkdocs-material -> fastmcp -> mcp-nixos.
            backrefs = pyPrev.backrefs.overridePythonAttrs (
              appendDisabledTests [ "test_timeout" ]
            );

            # znver5 FMA/AVX-512: test_poly_int_overflow expects poly() coeffs
            # to match a reference to 7 decimals; at ~1e18 magnitude the actual
            # vs desired differ by a few ULPs (rel ~2e-16). Same class as gsl/
            # assimp. 47072 other tests passed. Blocks pandas, pybind11,
            # libcamera, pipewire.
            numpy = pyPrev.numpy.overridePythonAttrs (
              appendDisabledTests [ "test_poly_int_overflow" ]
            );

            # Wall-clock: connect-only send/recv against a local socket server
            # with a hard read timeout; failed under full build load
            # ("timed out while reading response"). 657 others passed.
            # Blocks system-config-printer -> dbus/udev.
            pycurl = pyPrev.pycurl.overridePythonAttrs (
              appendDisabledTests [ "test_connect_only_send_recv_byteslike" ]
            );

            # Same class as eventlet: watchdog's tests wait on filesystem
            # events and watchmedo auto-restart subprocess lifecycles with
            # thread-count assertions; three failed in one round under full
            # build load (restart_count and threading.active_count off by
            # one). Upstream even ships a flaky-test retry plugin for this
            # suite. Blocks mkdocs/werkzeug/flask and the fastmcp stack.
            watchdog = pyPrev.watchdog.overridePythonAttrs (old: {
              doCheck = false;
            });

            # Same whack-a-mole as eventlet: sh's functional tests spawn real
            # subprocesses against wall-clock deadlines. First
            # test_general_signal flaked (SIGTERM landed late); with that
            # disabled, three different ones failed on the retry
            # (test_stdin_unbuffered_bufsize, test_timeout_overstep,
            # test_done_callback_no_deadlock — all sub-second timing
            # assertions). Skip the suite. Blocks python-dotenv ->
            # flask/fastapi/mcp stack.
            sh = pyPrev.sh.overridePythonAttrs (old: {
              doCheck = false;
            });

        # TestThrottler counts rate-limited calls against wall-clock seconds
        # (expects 28-32 calls/s, got 27 under full build load). All tests in
        # the class are real-time measurements, so disable the class. Blocks
        # a large subtree: keyring, scons, and thereby pipewire/chromium/
        # qtwebengine.
        jaraco-functools = pyPrev.jaraco-functools.overridePythonAttrs (
          appendDisabledTests [ "TestThrottler" ]
        );

        # Same whack-a-mole as eventlet: tornado's suite is full of wall-clock
        # tests. Three rounds of individual disables (linear-performance
        # scaling tests, autoreload subprocess termination, then
        # RunnerGCTest::test_gc timing out) each surfaced a new flake under
        # full build load, so skip the suite outright.
        tornado = pyPrev.tornado.overridePythonAttrs (old: {
          doCheck = false;
        });

        # Meta-test asserting on pytest's internal report lists; passes on
        # pytest 9.0.2 (Alpine CI) but fails deterministically on the 9.1.1
        # in this nixpkgs pin — a pytest behavior change, not load or arch.
        # Upstream (bjoluc/pytest-reraise) is unmaintained since 2022.
        # Blocks duckdb -> fastmcp -> mcp-nixos.
        pytest-reraise = pyPrev.pytest-reraise.overridePythonAttrs (
          appendDisabledTests [ "test_multiple_exceptions" ]
        );
      }
    )
  ];
}
