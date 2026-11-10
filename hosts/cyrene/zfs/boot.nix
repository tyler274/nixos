{
  config,
  pkgs,
  lib,
  ...
}:

let
  cyreneZfs = import ./lib.nix { inherit lib; };
  zfsAttr = config.boot.zfs.package.kernelModuleAttribute;
  upstreamLinux73 = pkgs.linuxKernel.packages.linux_7_3;
  # OpenZFS 2.4.4 caps at Linux 7.2, which nixpkgs has dropped. Apply the
  # 7.3 compat backports Ubuntu ships (see patches/linux-7.3/README.md) to the
  # kernel module only; userspace stays the cached pkgs.zfs_2_4.
  linux73Zfs = upstreamLinux73.extend (
    _: super: {
      ${zfsAttr} = super.${zfsAttr}.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ./patches/linux-7.3/linux-7.3-iops-create-no-flag.patch
          ./patches/linux-7.3/linux-7.3-bvec-iter-bi-offset.patch
          ./patches/linux-7.3/linux-cpu-feature-enabled.patch
          ./patches/linux-7.3/linux-7.3-kthread-init-fs.patch
          ./patches/linux-7.3/bump-Linux-Maximum-7.3.patch
        ];
        # nixpkgs greps META for the packaged Linux-Maximum; follow the bump.
        postPatch =
          let
            from = "Linux-Maximum: *${lib.escapeRegex "7.2"}$";
            to = "Linux-Maximum: *${lib.escapeRegex "7.3"}$";
          in
          assert lib.assertMsg (lib.hasInfix from old.postPatch)
            "zfs postPatch no longer checks Linux-Maximum 7.2; revisit hosts/cyrene/zfs/boot.nix";
          builtins.replaceStrings [ from ] [ to ] old.postPatch;
        meta = old.meta // {
          broken = false;
        };
      });
    }
  );
  kernelPackages =
    assert lib.assertMsg (lib.versions.majorMinor upstreamLinux73.kernel.version == "7.3")
      "linux_7_3 is no longer 7.3; revisit hosts/cyrene/zfs/boot.nix";
    lib.warnIf (!upstreamLinux73.${zfsAttr}.meta.broken)
      "nixpkgs ZFS now supports Linux 7.3: drop hosts/cyrene/zfs/patches/linux-7.3 and the override in boot.nix"
      linux73Zfs;
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

  # Pinned to 7.3 with patched ZFS until nixpkgs' ZFS supports it; then go back
  # to picking the newest kernel whose ZFS module isn't marked broken.
  boot.kernelPackages = kernelPackages;

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
    # and `sbctl setup --migrate` only updates ITS OWN store - it has no idea
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
  # the Samsung 990 PRO (see default.nix). Reclaim the unused zvol once:
  #   swapon --show | grep -q rpool/swap && echo "still in use" && exit 1
  #   sudo zfs destroy rpool/swap
  #swapDevices = [
  #  { device = "/dev/zvol/rpool/swap"; }
  #];
}
