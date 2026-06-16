{
  config,
  lib,
  pkgs,
  ...
}:

{
  # AMD CPU microcode updates (security patches, errata fixes).
  hardware.cpu.amd.updateMicrocode = true;

  # Redistributable firmware blobs (includes AMDGPU, Wi-Fi, etc.).
  hardware.enableRedistributableFirmware = true;

  # KVM virtualisation via AMD-V; required by docker/incus/waydroid.
  boot.kernelModules = [ "kvm-amd" ];

  # AMD P-State EPP driver (kernel 6.1+). "active" mode delegates
  # frequency/voltage decisions to the firmware (CPPC2), which is
  # significantly more efficient than the legacy ACPI cpufreq driver.
  # Alternatives: "guided" (OS hints, firmware decides), "passive" (OS drives cpufreq).
  boot.kernelParams = [ "amd_pstate=guided" ];

  # power-profiles-daemon lets KDE's power widget set EPP profiles:
  #   performance  → EPP "performance"
  #   balanced     → EPP "balance_performance"  (default)
  #   power-saver  → EPP "power"
  # Do not set powerManagement.cpuFreqGovernor alongside this; it would conflict.
  services.power-profiles-daemon.enable = true;

  powerManagement.enable = true;
  powerManagement.cpuFreqGovernor = "schedutil";
}
