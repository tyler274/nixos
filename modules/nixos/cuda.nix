# CUDA + Docker NVIDIA support for WSL.
#
# GPU access in WSL flows from the Windows NVIDIA driver, which is mapped into
# WSL at /usr/lib/wsl/lib/. The Linux kernel-side NVIDIA driver
# (`hardware.nvidia.enable`) MUST NOT be enabled here — it would conflict with
# the Windows driver stub. `linuxPackages.nvidia_x11` is intentionally omitted
# for the same reason.
#
# This module:
#   1. Enables `hardware.graphics` (renamed from `hardware.opengl` in unstable)
#      so userspace GPU library plumbing is available.
#   2. Sets `nixpkgs.config.cudaSupport` so CUDA-aware package variants
#      (pytorch, jax, etc.) are pulled from the binary cache.
#   3. Installs the CUDA toolkit (nvcc + cudart) and nvtop.
#   4. Puts /usr/lib/wsl/lib on LD_LIBRARY_PATH so libcuda.so.1 resolves to
#      the Windows-side driver stub.
#   5. Enables Docker with the NVIDIA container runtime so containerized
#      CUDA workloads can see the GPU via `--gpus all`.

{ pkgs, lib, ... }:

let
  # Pin to CUDA 13.2 (matches the version targeted by NVIDIA's cuda-samples
  # repo). The default `cudaPackages` alias in nixpkgs-unstable still resolves
  # to 12.9 as of this writing; selecting `cudaPackages_13_2` explicitly keeps
  # nvcc, cudart, and cudatoolkit on the same major/minor.
  cudaPkgs = pkgs.cudaPackages_13_2;
in
{
  hardware.graphics.enable = true;

  nixpkgs.config.cudaSupport = true;

  environment.systemPackages = with pkgs; [
    cudaPkgs.cudatoolkit
    cudaPkgs.cuda_cudart
    cudaPkgs.cuda_nvcc
    nvtopPackages.nvidia

    # Host build toolchain for CUDA samples (cuda-samples is CMake-based,
    # invokes nvcc which shells out to a host C/C++ compiler).
    cmake
    gnumake
    gcc
    pkg-config
  ];

  environment.sessionVariables = {
    CUDA_PATH = "${cudaPkgs.cudatoolkit}";
    LD_LIBRARY_PATH = "/usr/lib/wsl/lib:${lib.makeLibraryPath [
      cudaPkgs.cudatoolkit
      cudaPkgs.cuda_cudart
    ]}";
  };

  virtualisation.docker.enable = true;
  hardware.nvidia-container-toolkit = {
    enable = true;
    # WSL gets its NVIDIA driver from the Windows host (mapped into
    # /usr/lib/wsl/lib), not from a NixOS-side kernel module. The default
    # assertion expects `hardware.nvidia.*` or `services.xserver.videoDrivers`
    # to be set, neither of which applies here.
    suppressNvidiaDriverAssertion = true;
  };
}
