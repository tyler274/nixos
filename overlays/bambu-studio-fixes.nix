# Bambu Studio on nixos-unstable is 02.08.00.50; nixos-26.05 is still
# 02.05.00.67. This overlay:
#   1. Fetches upstream v02.08.02.61
#      (https://github.com/bambulab/BambuStudio/releases/tag/v02.08.02.61)
#   2. Replaces nixpkgs' packaging patches, which do not apply on that tag
#      (webkit insert point moved, DeviceWeb node hashes/BOM changed, several
#      cmake_minimum_required lines already bumped, no-cereal.patch is corrupt)
#   3. Keeps hardened mimalloc: null LayeredNozzleGroupResult derefs, mixed
#      tbbmalloc, and the wxMediaCtrl3 paint-thread race.
#
# Drop this overlay once nixpkgs ships 02.08.02.61 (or newer) with equivalent
# packaging patches; keep the crash-fix patches until they are upstream.
final: prev:
let
  version = "02.08.02.61";
in
{
  bambu-studio = prev.bambu-studio.overrideAttrs (old: {
    inherit version;
    src = prev.fetchFromGitHub {
      owner = "bambulab";
      repo = "BambuStudio";
      tag = "v${version}";
      hash = "sha256-pj0oyHgREcmvu3Y+d99IatHXQH5CF53Ku6baPdWptyU=";
    };
    patches = [
      ./patches/bambu-studio/0000-nixpkgs-packaging-for-02.08.02.61.patch
      ./patches/bambu-studio/0001-fix-null-nozzle-group-deref.patch
      ./patches/bambu-studio/0002-drop-tbbmalloc-use-process-allocator.patch
      ./patches/bambu-studio/0003-wxmediactrl3-deep-copy-frame.patch
    ];
  });
}
