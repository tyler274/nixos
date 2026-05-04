# TODO: replace this stub with the output of
#   nixos-generate-config --show-hardware-config
# captured during the laptop's first install. The fileSystems / swapDevices /
# initrd module list must come from the live machine.

{ lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # PLACEHOLDER: replace with the real fileSystems / swapDevices output of
  # `nixos-generate-config` from the laptop install. The values below only
  # exist so `nix flake check` can evaluate this configuration without a real
  # disk attached.
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/PLACEHOLDER";
    fsType = "ext4";
  };
  fileSystems."/boot" = lib.mkDefault {
    device = "/dev/disk/by-label/BOOT-PLACEHOLDER";
    fsType = "vfat";
  };
}
