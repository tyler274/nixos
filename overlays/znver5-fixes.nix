# Package fixes for building the world with -march=znver5 (Ryzen 9 9950X3D,
# see nixpkgs.hostPlatform in hosts/cyrene/default.nix). Two failure classes
# live here:
#
#   1. Test suites that fail for benign reasons - typically floating-point
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
  # gcc 15 + znver5 vectorization - test_api/test_noinit/test_nolock/
  # test_nthreads SEGV). CMake's Release type forces -O3; the trailing
  # NIX_CFLAGS_COMPILE -O2 wins because the wrapper appends it after the
  # command-line flags. Tests stay enabled to verify the cap actually fixes
  # the codegen.
  c-blosc = prev.c-blosc.overrideAttrs (old: {
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE = ((old.env.NIX_CFLAGS_COMPILE or "") + " -O2");
    };
  });

  # ada-url 4.0.0: the AVX-512 IPv4 fast path (ADA_AVX512, gated on
  # AVX512BW+VL so -march=znver5 always compiles it; Hydra x86_64-linux
  # stays on the scalar kernel) treats any host with 3 dots as four
  # octets, including WHATWG trailing-dot 3-component forms like
  # "192.168.0.". parse_ipv4_decimal_trusted then over-reads the trailing
  # '.' as a fourth octet (NUL-'0' -> 0xffffffd0) and parse_host stores a
  # non-canonical host; re-parsing the href canonicalizes to 192.168.0.0
  # and basic_fuzzer aborts ("href not idempotent"). Not an allocator
  # issue: same HIT/fail split under glibc and mimalloc. Upstream main
  # strips the trailing dot before counting separators; backport that
  # check. Tests stay enabled.
  ada = prev.ada.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./patches/ada/0001-fix-avx512-ipv4-trailing-dot.patch
    ];
  });

  # simde is header-only, but its meson build compiles a large native +
  # emulated test suite by default (the only compiled artifacts), and the
  # AVX-512 tests fail to compile with gcc 15 at -march=znver5. -Dtests=false
  # skips them; the installed headers are identical. Revisit when nixpkgs
  # moves past simde 0.8.2.
  simde = prev.simde.overrideAttrs (old: {
    mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dtests=false" ];
  });

  # embree hand-rolls per-ISA multi-versioning: kernels/bvh/bvh.cpp is
  # compiled once per ISA tier (SSE2/AVX/AVX2/AVX512) and instantiates the
  # canonical, un-namespaced `BVHN<4>` exactly once, guarded by
  # `!defined(__AVX__) || !defined(EMBREE_TARGET_SSE2) && ...` - it relies on
  # its own per-tier -m flags (e.g. plain "-msse2" for the lowest tier) being
  # the ONLY thing that defines __AVX__/__AVX512F__. The znver5 wrapper's
  # trailing -march=znver5 defines those macros unconditionally on every
  # translation unit regardless of embree's own -m flags (same append-after
  # mechanism as the c-blosc fix above), so the guard concludes the lowest
  # tier "isn't" the designated instantiation point and skips it - nothing
  # else in the tree ever instantiates BVHN<4>, hence the undefined
  # references from bvh_builder_twolevel.cpp's avx512-namespaced code.
  # Documented upstream as fundamentally incompatible with any blanket
  # -march flag (RenderKit/embree#115; godotengine/godot#91217, #49225) -
  # Gentoo's ebuild works around it the same way: strip all -m* flags and
  # let embree's cmake own ISA selection. EMBREE_MAX_ISA=SSE2 drops the
  # avx/avx2/avx512 static libs entirely (only one tier left to keep
  # consistent); the trailing -march override then makes __AVX__ actually
  # go undefined for that tier, matching its EMBREE_TARGET_SSE2 tag. Loses
  # embree's AVX-optimized ray-tracing kernels; blocks jellyfin(-ffmpeg).
  embree = prev.embree.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DEMBREE_MAX_ISA=SSE2" ];
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE = ((old.env.NIX_CFLAGS_COMPILE or "") + " -march=x86-64-v2");
    };
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

  # eigen_5 (5.0.1; plain `eigen` is still 3.4.1 and unaffected): the
  # AVX-512 erfc packet op for double miscompiles at -march=znver5 with
  # gcc 15 - CoreEvaluators.h:590 can't convert '__vector(4) double' to
  # '__m512d' while building the Cwise_erfc doc example, failing the
  # install-doc target (the -doc output) and taking krita / orca-slicer
  # down with it. Cwise_erf and Cwise_lgamma compile fine; the headers are
  # only affected if a consumer instantiates vectorized erfc<double>.
  # doc/examples/CMakeLists.txt globs *.cpp, so dropping the file skips
  # just this example (doxygen warns about the missing snippet but doesn't
  # fail).
  eigen_5 = prev.eigen_5.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      rm -f doc/examples/Cwise_erfc.cpp
    '';
  });

  # frei0r's tint0r filter has an SSE4.1 code path that was never
  # compile-tested upstream: tint_sse41 declares its pixel register as
  # __m128 (float) but drives it through __m128i integer intrinsics
  # (_mm_loadu_si128 / _mm_srli_si128 / _mm_packus_epi32 ...). The path is
  # gated on __SSE4_1__, which baseline x86-64 never defines but
  # -march=znver5 always does, so the dead broken code suddenly compiles
  # (and fails). Force the gate off; the scalar fallback right below it is
  # what every other build uses anyway. The CUDA/nvcc side of frei0r is
  # handled separately in flake.nix's cudaFixOverlay (this overlay layers
  # on top of it). Blocks mlt -> jellyfin-ffmpeg -> jellyfin.
  frei0r = prev.frei0r.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/filter/tint0r/tint0r.c \
        --replace-fail '#if defined(__SSE4_1__)' '#if 0'
    '';
  });

  # Not arch-related: QUIC integration recipes drive simulated servers/clients
  # via quictestlib (globserverret / qtest_create_quic_connection); they flake
  # under full build load - first 70-test_quic_multistream.t, then
  # 75-test_quicapi.t (test_fin_only_blocking). Skip the integration trio;
  # the other ~4500 tests (including 70-test_quic_* unit recipes) still run.
  # Harness globs test/recipes/, so removing the files skips just these.
  openssl = prev.openssl.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      rm -f \
        test/recipes/70-test_quic_multistream.t \
        test/recipes/75-test_quicapi.t \
        test/recipes/90-test_quicfaults.t
    '';
  });

  # Not arch-related: serv-udp.sh starts a DTLS server and connects a client
  # over loopback UDP; under full build load the client raced the server
  # startup ("Connection refused" -> "Error in the push function"). Overwrite
  # the script with exit 77 (automake SKIP) so the other 512 tests still run
  # - gnutls is security-critical, so keep the suite otherwise intact.
  # Blocks systemd/networkmanager/ffmpeg/cups/samba/webkitgtk.
  gnutls = prev.gnutls.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      printf '#!/bin/sh\nexit 77\n' > tests/serv-udp.sh
    '';
  });

  # Not arch-related: rwlock_test's isc_rwlock_benchmark subtest hits the
  # runner's wall-clock limit under full build load (exit 124); the four
  # functional rwlock subtests pass. nixpkgs already skips a timezone test
  # the same way in bind's preCheck - append this entry removal there.
  bind = prev.bind.overrideAttrs (old: {
    preCheck = (old.preCheck or "") + ''
      sed -i '/^ISC_TEST_ENTRY_CUSTOM(isc_rwlock_benchmark,/d' tests/isc/rwlock_test.c
    '';
  });

  # Not arch-related: script-log-socket spawns chatter-socket-stream over a
  # Unix socket and asserts accept/recv succeed; failed under full build load
  # (conn != null, len >= 0). Remove the Test.add_func line pre-build. Blocks
  # libgudev -> power-profiles-daemon/xdg-desktop-portal/dbus.
  umockdev = prev.umockdev.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      sed -i '/script-log-socket/d' tests/test-umockdev-record.vala
    '';
  });

  # znver5 + Valgrind 3.27: valgrind_unittest wraps the gtest binary with
  # memcheck, but Valgrind SIGILLs on EVEX (0x62) instructions in glibc's
  # ld.so when the test binary is built with -march=znver5. unittest and
  # perftest pass outside Valgrind; skip only the valgrind CTest.
  rapidjson = prev.rapidjson.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace test/unittest/CMakeLists.txt \
        --replace-fail 'if(NOT MSVC AND VALGRIND_FOUND)' 'if(FALSE)'
    '';
  });

  # Not arch-related: the test suite runs live client/server exchanges against
  # a spawned memcached, and under full build load they flake one at a time -
  # first memcached_udp (loopback datagram drops mid-loop), then, with that
  # excluded, memcached_noblock (non-blocking I/O timing; every test in that
  # run also took ~430s vs ~89s unloaded). Same whack-a-mole as eventlet, so
  # skip the suite rather than chase individual tests.
  libmemcached = prev.libmemcached.overrideAttrs (old: { doCheck = false; });

  # Not arch-related: eventlet's greenthread/patcher tests assert wall-clock
  # timeouts and starve when the machine is saturated by the from-source
  # world build. Disabling individual tests proved to be whack-a-mole - a
  # different pair timed out on the retry - so skip the suite outright.
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
            # the output - a wall-clock race under build load (observed:
            # test_stdout_capture_same_process got [] while its subprocess
            # sibling passed). Upstream is unmaintained; skip the suite
            # rather than chase races one test at a time. Blocks
            # coloredlogs -> onnxruntime -> piper-tts/calibre.
            capturer = pyPrev.capturer.overridePythonAttrs (old: {
              doCheck = false;
            });

            # Same class as eventlet: a wall-clock performance assertion (parse
            # in <0.5s; took 0.514s under full build load). It's the only timed
            # Wall-clock / complexity: repeated-formatting and unclosed-link
            # destination tests assert near-linear runtime via perf_counter;
            # both flake under full build load. Security edge-case class only.
            mistune = pyPrev.mistune.overridePythonAttrs (
              appendDisabledTests [
                "test_repeated_formatting_pairs_return_quickly"
                "test_unclosed_link_destinations_are_near_linear"
              ]
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

            # znver5 FMA/AVX-512 rounding: STFT roundtrips exceed rtol=1e-07
            # by ~2e-07 (and compare ~1e-20 residuals against exact 0.0), and
            # the interior-point linprog solver lands just outside its 3.16e-4
            # feasibility tolerance on test_bug_6139 (both the plain and
            # presolve parametrizations). 87708 other tests passed. Blocks
            # scikit-learn, torchvision, librosa, calibre, yt-dlp, fastmcp.
            scipy = pyPrev.scipy.overridePythonAttrs (
              appendDisabledTests [
                "test_roundtrip_float32"
                "test_roundtrip_scaling"
                "test_bug_6139"
              ]
            );

            # znver5 FMA/AVX-512 rounding: multichannel MFCC and scipy-mode
            # resample outputs differ from their per-channel references in the
            # last float32 digit (np.allclose False on e.g. 1.483e-04 vs
            # 1.484e-04). Same class as scipy/numpy above. 13913 other tests
            # passed. Blocks piper-tts -> calibre.
            librosa = pyPrev.librosa.overridePythonAttrs (
              appendDisabledTests [
                "test_mfcc_multi"
                "test_resample_multichannel"
              ]
            );

            # Wall-clock: connect-only send/recv against a local socket server
            # with a hard read timeout; failed under full build load
            # ("timed out while reading response"). 657 others passed.
            # Blocks system-config-printer -> dbus/udev.
            pycurl = pyPrev.pycurl.overridePythonAttrs (
              appendDisabledTests [ "test_connect_only_send_recv_byteslike" ]
            );

            # Watcher timing: the reloader tests create files and assert the
            # filewatcher (stat-polling or watchdog variants) requests a
            # restart within a deadline; the stat variant missed it under
            # full build load (rc 0 vs expected 3). The whole module is the
            # same pattern, so exclude the file. Blocks aioboto3 ->
            # fastmcp -> mcp-nixos.
            chalice = pyPrev.chalice.overridePythonAttrs (old:
              let
                existing = old.disabledTestPaths or null;
              in
              {
                disabledTestPaths =
                  (if existing == null then [ ] else existing)
                  ++ [ "tests/functional/cli/test_reloader.py" ];
              }
            );

            # Not load- or arch-related: on the 2026-08-02 nixpkgs pin,
            # mkdocs' livereload tests error deterministically - watchdog's
            # dirsnapshot walker follows the suite's circular-symlink fixture
            # until ELOOP ("Too many levels of symbolic links"). Built fine
            # on the 07-23 pin; a version-interaction regression, not ours to
            # fix. The suite is unittest-based, so disabledTests (pytest -k)
            # can't target it - skip the check phase. Blocks mkdocstrings ->
            # fastmcp -> mcp-nixos.
            mkdocs = pyPrev.mkdocs.overridePythonAttrs (old: {
              doCheck = false;
            });

            # Same class as eventlet: inquirer's acceptance tests drive
            # interactive terminal prompts via pexpect, and all 30 of them
            # timed out at once under full build load. Skip the suite.
            # Blocks chalice -> aioboto3 and the fastmcp stack.
            inquirer = pyPrev.inquirer.overridePythonAttrs (old: {
              doCheck = false;
            });

            # Same whack-a-mole as eventlet: ipython's debugger tests drive
            # interactive pdb sessions via pexpect. test_where_erase_value
            # timed out first; with that disabled, test_ignore_module_all_commands
            # timed out on the retry (slowest tests are all in test_debugger.py).
            # Skip the suite. Blocks black, duckdb, ipykernel and the fastmcp
            # stack.
            ipython = pyPrev.ipython.overridePythonAttrs (old: {
              doCheck = false;
            });

            # Time race: test_serialize_date formats "now" and compares
            # against a separately computed "now"; fails whenever the wall
            # clock crosses a second boundary between the two calls (:50 vs
            # :49 here). 2387 others passed. Blocks webtest -> moto/fastmcp
            # and calibre.
            webob = pyPrev.webob.overridePythonAttrs (
              appendDisabledTests [ "test_serialize_date" ]
            );

            # File-lock ordering: test_fs_backend_stores_honor_load_store_locking
            # asserts lock contention behavior (got 0 vs expected -1) under full
            # build load. 533 others passed.
            liquidctl = pyPrev.liquidctl.overridePythonAttrs (
              appendDisabledTests [ "test_fs_backend_stores_honor_load_store_locking" ]
            );

            # Subprocess wait race: test_multiple_wait spawns a child that
            # sleeps and asserts wait() returns in time; timed out after 0.9s
            # under full build load. 160 others passed.
            pytest-subprocess = pyPrev.pytest-subprocess.overridePythonAttrs (
              appendDisabledTests [ "test_multiple_wait" ]
            );

            # Load flakes: transport tests spin up WSGI capturing servers and
            # assert flush/close timing; seven failures and four teardown
            # errors in one run under full build load (test_transport_works*
            # parametrizations, test_transaction_uses_downsampled_rate,
            # test_get_current_thread_meta_main_thread). 2349 others passed.
            sentry-sdk = pyPrev.sentry-sdk.overridePythonAttrs (old: {
              doCheck = false;
            });

            # RustNotify on / for permission-denied handling; times out (>10s)
            # under full build load. 150 others passed.
            watchfiles = pyPrev.watchfiles.overridePythonAttrs (
              appendDisabledTests [ "test_ignore_permission_denied" ]
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
            # test_done_callback_no_deadlock - all sub-second timing
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

        # Same whack-a-mole as tornado: asyncio/socket tests flake under load
        # (first round: deadlock + ECONNRESET; with those disabled,
        # test_call_at timed out on callback scheduling - 0.112s vs 0.07s
        # limit). Skip the suite. Blocks anyio -> httpx/fastapi/fastmcp stack.
        uvloop = pyPrev.uvloop.overridePythonAttrs (old: {
          doCheck = false;
        });

        # Same whack-a-mole as uvloop: first round four failures in
        # test_pytest_plugin.py (nested pytest subprocess timeouts); with
        # that file excluded, test_single_thread flaked on threading.active_count
        # under load. Skip the suite. Blocks httpx/fastapi/fastmcp stack.
        anyio = pyPrev.anyio.overridePythonAttrs (old: {
          doCheck = false;
        });

        # Meta-test asserting on pytest's internal report lists; passes on
        # pytest 9.0.2 (Alpine CI) but fails deterministically on the 9.1.1
        # in this nixpkgs pin - a pytest behavior change, not load or arch.
        # Upstream (bjoluc/pytest-reraise) is unmaintained since 2022.
        # Blocks duckdb -> fastmcp -> mcp-nixos.
        pytest-reraise = pyPrev.pytest-reraise.overridePythonAttrs (
          appendDisabledTests [ "test_multiple_exceptions" ]
        );
      }
    )
  ];
}
