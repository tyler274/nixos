{ lib, ... }:
{
  nixpkgs.config.cudaSupport = true;

  hardware = {
    enableRedistributableFirmware = true;

    cpu = {
      amd.updateMicrocode = true;
      intel.updateMicrocode = true;
    };

    graphics = {
      enable = true;
      enable32Bit = true;
    };

    nvidia = {
      modesetting.enable = true;
      open = false;
      # package must be set per-host: nvidiaPackages.latest vs .production
    };

    nvidia-container-toolkit.enable = true;
  };

  services.xserver.videoDrivers = lib.mkForce [ "nvidia" ];

  # NVIDIA 610+ enables the per-plane DRM COLOR_PIPELINE API by default (Linux
  # 6.19+). KWin 6.6.x mishandles pipelines containing non-bypassable colorops
  # and segfaults in DrmAbstractColorOp::matchPipeline on login (testPresentation
  # during the first composite). KWin 6.7 rewrites the color pipeline and is
  # unaffected; until then, disable hardware color offload so KWin falls back to
  # shader-based color management. Set as a kernel param so it applies even when
  # nvidia-drm is loaded from the initrd.
  # Refs: NVIDIA 610 release notes ("Wayland Known Issues"); KWin !9042/!9278.
  boot.kernelParams = [ "nvidia-drm.color_pipeline=0" ];
}
