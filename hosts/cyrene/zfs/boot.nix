{ config, pkgs, lib, ... }:

let
  cyreneZfs = import ./lib.nix { inherit lib; };
  zfsCompatibleKernelPackages = lib.filterAttrs (
    name: kernelPackages:
    (builtins.match "linux_[0-9]+_[0-9]+" name) != null
    && (builtins.tryEval kernelPackages).success
    && (!kernelPackages.${config.boot.zfs.package.kernelModuleAttribute}.meta.broken)
  ) pkgs.linuxKernel.packages;
  latestKernelPackage = lib.last (
    lib.sort (a: b: (lib.versionOlder a.kernel.version b.kernel.version)) (
      builtins.attrValues zfsCompatibleKernelPackages
    )
  );
in
{
  boot.supportedFilesystems = [
    "zfs"
    "ntfs"
  ];
  # ZFS must also be available in the initrd so the root pool is importable
  # early in boot and any ZFS fileSystems entries (e.g. /tmp) can be mounted
  # before userspace starts.
  boot.initrd.supportedFilesystems = [ "zfs" ];
  boot.kernelParams = [ "console=tty1" ];
  boot.zfs.forceImportRoot = true;
  boot.zfs.requestEncryptionCredentials = [ "rpool" ];
  # Gated on localBackupAttached (see lib.nix): importing the pool while its
  # disk is detached retries for 60s and stalls every boot.
  boot.zfs.extraPools = lib.optionals cyreneZfs.localBackupAttached [ "local-backup" ];
  # Unique per-host ZFS hostid. forceImportRoot above lets the root pool
  # reconcile this on the next boot's forced import without an export (which is
  # impossible for a live system root); see also local-backup, which needs a
  # one-time `zpool import -f local-backup` after the id changes.
  networking.hostId = "69e5e3ea";

  # Note this might jump back and forth as kernels are added or removed.
  boot.kernelPackages = latestKernelPackage;

  boot.loader = {
    efi = {
      efiSysMountPoint = "/boot";
      canTouchEfiVariables = true;
    };
    # lanzaboote replaces the systemd-boot install step with signed-UKI installs.
    systemd-boot = {
      enable = lib.mkForce false;
      configurationLimit = 20;
    };
  };

  boot.lanzaboote = {
    enable = true;
    # Point straight at sbctl's own canonical key store rather than a separate
    # copy: sbctl >=0.15 moved from /usr/share/secureboot to /var/lib/sbctl,
    # and `sbctl setup --migrate` only updates ITS OWN store — it has no idea
    # about any other directory. Keeping pkiBundle in sync with wherever sbctl
    # actually manages keys means `sbctl enroll-keys`/`sbctl rotate-keys` and
    # what lanzaboote signs with can never drift apart again. Back this
    # directory up offline.
    pkiBundle = "/var/lib/sbctl";
  };

  boot.kernel.sysctl = {
    # ZFS manages its own page cache via the ARC; a high swappiness
    # causes the kernel to race against ZFS for the same pages and
    # makes OOM situations much worse. 10 is the standard ZFS recommendation.
    "vm.swappiness" = 10;
    # Tell the kernel to start reclaiming memory earlier (at 3% free)
    # rather than waiting until it is nearly exhausted.
    "vm.min_free_kbytes" = 2097152; # 2 GiB
  };

  boot.zswap = {
    enable = true;
    compressor = "zstd";
    zpool = "zsmalloc";
    maxPoolPercent = 25;
  };

  # The ZVOL swap device is disabled because it was causing issues with the
  # kernel. The ARC cache was not able to keep up with the swap requests, and
  # the kernel was swapping out pages that were still in use. Swap now lives on
  # the Samsung 980 PRO (see default.nix). Reclaim the unused zvol once:
  #   swapon --show | grep -q rpool/swap && echo "still in use" && exit 1
  #   sudo zfs destroy rpool/swap
  #swapDevices = [
  #  { device = "/dev/zvol/rpool/swap"; }
  #];
}
