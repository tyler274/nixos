# Bambu Studio on nixos-unstable is 02.08.00.50; nixos-26.05 is still
# 02.05.00.67. This overlay:
#   1. Fetches upstream v02.08.02.61
#      (https://github.com/bambulab/BambuStudio/releases/tag/v02.08.02.61)
#   2. Replaces nixpkgs' packaging patches, which do not apply on that tag
#      (webkit insert point moved, DeviceWeb node hashes/BOM changed, several
#      cmake_minimum_required lines already bumped, no-cereal.patch is corrupt)
#   3. Keeps hardened mimalloc: null LayeredNozzleGroupResult derefs, mixed
#      tbbmalloc, and the wxMediaCtrl3 paint-thread race.
#   4. Builds the device_page Vite bundle offline (fetchPnpmDeps + pnpm 10)
#      and copies it into resources/web/device_page/dist before CMake
#      configure, so Filament Management can load. Upstream CMake downloads
#      Node + pnpm at configure time, which the Nix sandbox cannot do.
#
# The C++ package is built from a nixpkgs instantiation *without* this
# host's gcc.arch=znver5, so deps come from Hydra instead of a from-source
# world rebuild. Drop this overlay once nixpkgs ships 02.08.02.61 (or newer)
# with equivalent packaging; keep the crash-fix patches until they are
# upstream.
final: prev:
let
  version = "02.08.02.61";

  cacheablePkgs = import prev.path {
    system = prev.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };

  src = cacheablePkgs.fetchFromGitHub {
    owner = "bambulab";
    repo = "BambuStudio";
    tag = "v${version}";
    hash = "sha256-pj0oyHgREcmvu3Y+d99IatHXQH5CF53Ku6baPdWptyU=";
  };

  # Lockfile was generated with pnpm 10.12.1 and uses `pnpm.overrides`, a
  # field pnpm 11 no longer reads (ERR_PNPM_LOCKFILE_CONFIG_MISMATCH).
  pnpm = cacheablePkgs.pnpm_10;

  devicePageSourceRoot = "${src.name}/src/slic3r/GUI/DeviceWeb/device_page";

  devicePageDist = cacheablePkgs.stdenv.mkDerivation {
    pname = "bambu-studio-device-page";
    inherit version src;
    sourceRoot = devicePageSourceRoot;

    pnpmDeps = cacheablePkgs.fetchPnpmDeps {
      pname = "bambu-studio-device-page";
      inherit version src pnpm;
      sourceRoot = devicePageSourceRoot;
      fetcherVersion = 3;
      hash = "sha256-bib4YXWfbBRmU67uVIsPCfsp8GV4G2DyRstrUyH9n6c=";
    };

    nativeBuildInputs = [
      cacheablePkgs.nodejs
      pnpm
      cacheablePkgs.pnpmConfigHook
      cacheablePkgs.writableTmpDirAsHomeHook
    ];

    buildPhase = ''
      runHook preBuild
      pnpm run build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r dist/. $out/
      runHook postInstall
    '';
  };
in
{
  bambu-studio = cacheablePkgs.bambu-studio.overrideAttrs (old: {
    inherit version src;
    patches = [
      ./patches/bambu-studio/0000-nixpkgs-packaging-for-02.08.02.61.patch
      ./patches/bambu-studio/0001-fix-null-nozzle-group-deref.patch
      ./patches/bambu-studio/0002-drop-tbbmalloc-use-process-allocator.patch
      ./patches/bambu-studio/0003-wxmediactrl3-deep-copy-frame.patch
    ];

    # preConfigure, not preBuild: cmake runs in a separate build/ dir, so
    # relative copies in preBuild land in the wrong place.
    preConfigure =
      ''
        mkdir -p resources/web/device_page/dist
        cp -r ${devicePageDist}/. resources/web/device_page/dist/
      ''
      + (old.preConfigure or "");

    passthru = (old.passthru or { }) // {
      inherit devicePageDist;
    };
  });
}
