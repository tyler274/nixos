{ config, pkgs, ... }:

{ 
  boot.supportedFilesystems = [ "zfs" "ntfs" ];
  networking.hostId = "48cd5bc1";
  boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
  boot.loader.efi.efiSysMountPoint = "/boot/efi";
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.generationsDir.copyKernels = true;
  boot.loader.grub.efiInstallAsRemovable = true;
  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.loader.grub.copyKernels = true;
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.zfsSupport = true;
  boot.loader.grub.extraPrepareConfig = ''
  mkdir -p /boot/efis
  for i in  /boot/efis/*; do mount $i ; done

  mkdir -p /boot/efi
  mount /boot/efi
'';
boot.loader.grub.extraInstallCommands = ''
ESP_MIRROR=$(mktemp -d)
cp -r /boot/efi/EFI $ESP_MIRROR
for i in /boot/efis/*; do
 cp -r $ESP_MIRROR/EFI $i
done
rm -rf $ESP_MIRROR
'';
boot.loader.grub.devices = [
      "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S73WNJ0TA08364H"
    ];
users.users.root.initialHashedPassword = "$6$vb/z0RxvkSqBDVlE$GuJFN90Karj9Ao9uQ/4vBdzMrZImnZeTHhQpQ6Smskrhj.udjK0irW89rtsnVicAlNb5re.vloBp7EDFyTxKx.";
}
