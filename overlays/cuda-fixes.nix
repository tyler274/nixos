# Workaround for https://github.com/NixOS/nixpkgs/issues/544701: CMake
# 4.2+ hard-fails FindCUDAToolkit when CUDAToolkit_ROOT lacks bin/nvcc,
# and nixpkgs' setup-cuda-hook only collects host-side deps (nvcc is a
# nativeBuildInput), so packages whose CMake runs find_package(CUDAToolkit)
# fail to configure. Pre-seed CUDAToolkit_ROOT with nvcc's package root:
# user preConfigure runs before hook-registered ones, and the hook appends
# to any existing value, so nvcc survives into the final env var and
# -DCUDAToolkit_ROOT flag. Remove once nixpkgs PR #545542 reaches
# nixos-unstable.
final: prev:
let
  seedNvccIntoToolkitRoot = old: {
    preConfigure = ''
      if nvccBin="$(type -P nvcc)"; then
        export CUDAToolkit_ROOT="''${CUDAToolkit_ROOT:+$CUDAToolkit_ROOT;}''${nvccBin%/bin/nvcc}"
      fi
    '' + (old.preConfigure or "");
  };
  # The seed above is a no-op unless nvcc is actually on PATH, which
  # requires cuda_nvcc in nativeBuildInputs (buildInputs bin/ dirs
  # don't reach PATH under strictDeps). For packages that only consume
  # a CUDA-enabled opencv via its exported OpenCVConfig.cmake
  # (find_package(CUDAToolkit) at OpenCVConfig.cmake:86), add nvcc to
  # PATH too.
  seedNvccWithNvccOnPath = old:
    seedNvccIntoToolkitRoot old
    // {
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
        final.cudaPackages.cuda_nvcc
      ];
    };
in
{
  # Transitively fixes the CUDA onnxruntime.
  cudaPackages = prev.cudaPackages.overrideScope (
    cudaFinal: cudaPrev: {
      cudnn-frontend = cudaPrev.cudnn-frontend.overrideAttrs seedNvccIntoToolkitRoot;
    }
  );

  # oidn builds its CUDA backend as an ExternalProject; the nested cmake
  # re-runs find_package(CUDAToolkit) (devices/cuda/CMakeLists.txt:23)
  # and inherits only the env var, which lacks nvcc without the seed.
  # Blocks blender.
  openimagedenoise = prev.openimagedenoise.overrideAttrs seedNvccIntoToolkitRoot;

  # Same shape as oidn: ollama's llama.cpp CUDA runner is a nested
  # ExternalProject whose find_package(CUDAToolkit) (ggml-cuda's
  # CMakeLists) fails on the hook's nvcc-less env var. Upstream lists
  # ollama-cuda as fixed by the very same seed (issue #545286).
  # preConfigure still runs under buildGoModule, and the exported var
  # survives into the preBuild cmake invocation. ollama-cuda is a
  # separate top-level instantiation (acceleration = "cuda") used by
  # services.ollama.package (modules/nixos/ollama.nix), so it needs
  # its own override — fixing `ollama` alone leaves it untouched.
  ollama = prev.ollama.overrideAttrs seedNvccIntoToolkitRoot;
  ollama-cuda = prev.ollama-cuda.overrideAttrs seedNvccIntoToolkitRoot;

  # Same nvcc-less CUDAToolkit_ROOT bug, hit two ways here: frei0r
  # links cuda_nvcc directly (but only via buildInputs + strictDeps,
  # so nvcc is NOT on PATH and the plain seed no-ops), and
  # (transitively) find_package(OpenCV) re-triggers
  # find_package(CUDAToolkit) via OpenCVConfig.cmake since
  # cudaSupport is on for opencv too. Blocks mlt -> jellyfin.
  frei0r = prev.frei0r.overrideAttrs seedNvccWithNvccOnPath;

  # Pure opencv consumer (src/libslic3r/CMakeLists.txt:525
  # find_package(OpenCV)); has no CUDA inputs of its own at all, so
  # it needs nvcc on PATH, the seed, AND cuda_cudart in buildInputs —
  # after nvcc is found, FindCUDAToolkit still requires the cudart
  # library (CUDA_CUDART), which lives in the separate cuda_cudart
  # split package (frei0r carries it natively; bambu doesn't).
  bambu-studio = prev.bambu-studio.overrideAttrs (
    old:
    seedNvccWithNvccOnPath old
    // {
      buildInputs = (old.buildInputs or [ ]) ++ [
        final.cudaPackages.cuda_cudart
      ];
    }
  );
}
