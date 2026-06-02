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
}
