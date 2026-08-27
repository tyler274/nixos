{ lib, ... }:

{
  # Persistent compiler cache on the Samsung 980 PRO (single partition; it
  # handed swap+scratch duty to the 990 PRO - see scratch.nix/default.nix).
  #
  # Purpose: crash insurance for the from-source znver5 world build. Completed
  # derivations already survive any crash (they're registered into /nix/store
  # on rpool), and Nix can never resume a half-built derivation, so the only
  # crash exposure is a multi-hour compile restarting from zero. ccache writes
  # each object file to this cache as it compiles, so a restarted build
  # fast-forwards through everything compiled before the crash. The same
  # mechanism also covers the recurring "compiled for hours, failed in
  # checkPhase, fixed via disabledTests override, recompiles identically"
  # loop (znver5-fixes.nix is full of those).
  #
  # Deliberately NOT wrapping the whole world in ccacheStdenv: that would
  # change every derivation hash (one extra full world rebuild), and the
  # steady-state hit rate for dependency-cascade rebuilds is poor anyway
  # (compile lines embed dependency store paths, which change with every
  # upstream fix). Only the multi-hour monsters below are wrapped - they're
  # where all the crash exposure is concentrated.
  #
  # Unencrypted on purpose, unlike swap/scratch: it only ever holds object
  # code compiled from public nixpkgs sources, and encrypting it with an
  # ephemeral urandom key would defeat persistence - the whole point.
  #
  # One-time setup after the role-swap reboot (the 980 is idle then):
  #   sudo sgdisk --zap-all -I -n 1:0:0 -t 1:8300 -c 1:ccache \
  #     /dev/disk/by-id/nvme-Samsung_SSD_980_PRO_2TB_S6B0NL0TA08502B
  #   sudo mkfs.xfs -L ccache \
  #     /dev/disk/by-id/nvme-Samsung_SSD_980_PRO_2TB_S6B0NL0TA08502B-part1
  #   sudo mount /var/cache/ccache
  #   sudo chown root:nixbld /var/cache/ccache && sudo chmod 770 /var/cache/ccache
  #   echo 'max_size = 400G' | sudo tee /var/cache/ccache/ccache.conf
  # XFS to match the scratch mount (scratch.nix) - the small-object cache
  # workload is indifferent between xfs/ext4, so keep a single filesystem
  # type in play across both NVMe roles.
  fileSystems."/var/cache/ccache" = {
    device = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_2TB_S6B0NL0TA08502B-part1";
    fsType = "xfs";
    options = [
      "noatime"
      "nodev"
      "nosuid"
      # The filesystem is created manually once (steps above); don't hang
      # boot while it doesn't exist yet. Until it's mounted, tmpfiles still
      # creates the plain directory, so wrapped builds keep working (cache
      # just lands on rpool temporarily).
      "nofail"
      "X-mount.mkdir"
    ];
  };

  # programs.ccache.enable, the hardened ccacheWrapper (CCACHE_DIR/UMASK +
  # loud preflight), and nix.settings.extra-sandbox-paths all come from
  # modules/nixos/ccache.nix; this file only adds the per-package wraps.
  #
  # programs.ccache.packageNames is deliberately unused: it injects
  # `stdenv = ccacheStdenv` via .override, which every monster here
  # defeats - firefox swaps in its own LLVM stdenv, and anything
  # cudaSupport-enabled (blender, torch, onnxruntime) swaps in
  # cudaPackages.backendStdenv (both verified: the injected stdenv's
  # compiler never reaches the build). Each package gets the hook its
  # build system actually honors:
  #
  # - qtwebengine lives in the qt6Packages scope and DOES take a plain
  #   stdenv override (no cuda, and Qt's GN honors the stdenv compiler).
  #   kdePackages shares the same instantiation (verified: identical
  #   drvPath), so the Plasma stack picks this up too.
  #
  # - libreoffice-qt-fresh (desktop.nix) is a wrapper whose `unwrapped`
  #   callPackage arg is the real multi-hour build; that build takes a
  #   plain stdenv (verified: cc resolves to ccache-links-wrapper).
  #
  # - firefox-unwrapped ignores injected stdenvs (buildMozillaMach forces
  #   its own llvmPackages stdenv for LTO), but mozilla's configure has
  #   first-class ccache support: --with-ccache=ccache prefixes every
  #   compiler invocation, clang included.
  #
  # - blender is CMake but cudaSupport makes it use
  #   cudaPackages.backendStdenv, unreachable by stdenv override; CMake's
  #   compiler-launcher flags wrap whatever compiler the build ends up
  #   using. CUDA kernels via nvcc aren't cached; host C++ (the bulk) is.
  #
  # - electron (linux default = built from source with chromium's build
  #   machinery) is a wrapper derivation; the real GN build sits behind the
  #   wrapper's electron-unwrapped callPackage arg. Its custom clang
  #   toolchain ignores the wrapped stdenv entirely, and chromium/common.nix
  #   serializes gnFlags into configurePhase at eval time and strips the
  #   attr, so there's no gnFlags to override post-hoc. Instead splice
  #   chromium's own compiler-launcher hook - the cc_wrapper="ccache" GN
  #   arg (build/toolchain/cc_wrapper.gni), the documented way to ccache
  #   chromium - directly into the serialized `gn gen --args='...'` call,
  #   with ccache on PATH and CCACHE_DIR pointed at the shared cache
  #   (programs.ccache exposes it to the sandbox; CCACHE_UMASK replicates
  #   the wrapper's usual umask setup so all nixbld users share entries).
  #   The assert makes eval fail loudly if a nixpkgs bump reshapes the
  #   configurePhase instead of silently building uncached. Overlaying
  #   electron-source propagates through the top-level electron_NN /
  #   electron aliases via the fixpoint, so every app's runtime picks up
  #   the wrapped build. Rust/TS steps aren't cached; the C++ bulk is.
  #
  # - chromium is in the closure only through security.chromiumSuidSandbox
  #   (desktop-common.nix), whose `pkgs.chromium.sandbox` is an output of
  #   the full browser build. The browser is assembled in a private scope
  #   with no override hook, so graft a cc_wrapper-spliced browser over the
  #   `browser`/`sandbox` passthrough attrs; the sandbox consumer then pulls
  #   the ccached build and the pristine browser drv is never referenced.
  #
  # - onnxruntime (CUDA): same backendStdenv story as blender, same
  #   CMake-launcher fix.
  #
  # Deliberately NOT wrapped:
  #
  # - python3Packages.torch: same backendStdenv story as onnxruntime, but
  #   its cmake runs inside setup.py where cmakeFlags don't flow. The real
  #   fix would be ccache-wrapping cudaPackages.backendStdenv itself, which
  #   invalidates the entire CUDA subtree (opencv -> frei0r/mlt/jellyfin,
  #   just rebuilt) and risks subtle nvcc host-compiler breakage across all
  #   of it - not worth it mid-campaign. Revisit if torch actually flakes.
  nixpkgs.overlays = [
    (
      final: prev:
      let
        ccacheEnv = {
          CCACHE_DIR = "/var/cache/ccache";
          CCACHE_UMASK = "007";
        };

        # For chromium-family GN builds (electron, chromium.browser).
        ccacheGnBuild =
          unwrapped:
          unwrapped.overrideAttrs (
            old:
            assert lib.assertMsg (lib.hasInfix "gn gen --args='" (
              old.configurePhase or ""
            )) "GN ccache hook: configurePhase no longer matches; fix hosts/cyrene/ccache.nix";
            {
              nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.ccache ];
              configurePhase =
                builtins.replaceStrings
                  [ "gn gen --args='" ]
                  [
                    "gn gen --args='cc_wrapper=\"ccache\" "
                  ]
                  old.configurePhase;
              env = (old.env or { }) // ccacheEnv;
            }
          );

        # For CMake builds whose effective compiler is out of stdenv's
        # hands (e.g. cudaPackages.backendStdenv users).
        ccacheCmakeBuild =
          pkg:
          pkg.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.ccache ];
            cmakeFlags = (old.cmakeFlags or [ ]) ++ [
              "-DCMAKE_C_COMPILER_LAUNCHER=ccache"
              "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
            ];
            env = (old.env or { }) // ccacheEnv;
          });

        ccachedChromiumBrowser = ccacheGnBuild prev.chromium.browser;
      in
      {
        qt6Packages = prev.qt6Packages.overrideScope (
          qFinal: qPrev: {
            qtwebengine = qPrev.qtwebengine.override { stdenv = final.ccacheStdenv; };
          }
        );

        libreoffice-qt-stable = prev.libreoffice-qt-stable.override (old: {
          unwrapped = old.unwrapped.override { stdenv = final.ccacheStdenv; };
        });

        firefox-unwrapped = prev.firefox-unwrapped.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.ccache ];
          configureFlags = (old.configureFlags or [ ]) ++ [ "--with-ccache=ccache" ];
          env = (old.env or { }) // ccacheEnv;
        });

        blender = ccacheCmakeBuild prev.blender;

        electron-source =
          prev.electron-source
          // lib.mapAttrs (
            _: wrapper: wrapper.override { electron-unwrapped = ccacheGnBuild wrapper.unwrapped; }
          ) (lib.filterAttrs (n: _: lib.hasPrefix "electron_" n) prev.electron-source);

        chromium = prev.chromium // {
          browser = ccachedChromiumBrowser;
          sandbox = ccachedChromiumBrowser.sandbox;
        };

        onnxruntime = ccacheCmakeBuild prev.onnxruntime;
      }
    )
  ];
}
