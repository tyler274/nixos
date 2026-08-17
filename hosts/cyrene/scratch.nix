{ pkgs, ... }:

{
  # systemd-cryptsetup handles the boot-time mapping on its own, but the
  # cryptsetup CLI is needed for manual operations on the mapping (close,
  # status, resize) and isn't in PATH by default on NixOS. gptfdisk provides
  # sgdisk for maintaining the partition layout this file depends on.
  environment.systemPackages = [
    pkgs.cryptsetup
    pkgs.gptfdisk
  ];

  # Nix >= 2.24 moved daemon build scratch from /tmp to /nix/var/nix/builds
  # (upstream fix for the world-writable-/tmp build-dir CVE), so the
  # rpool/nixos/tmp dataset no longer catches builds — they were silently
  # landing on rpool/nixos/root and therefore inside every snapshot again.
  # Offload them to the Samsung 990 PRO (which took over swap+scratch duty
  # from the 980 PRO; the 980 now holds the persistent ccache — ccache.nix):
  #   part1: 512 GiB swap  (randomEncryption — see swapDevices in default.nix)
  #   part2: ~1.3 TiB Nix build scratch (this file)
  #
  # Losing this on reboot costs nothing: completed derivations are registered
  # into /nix/store (rpool) the moment they finish, and Nix cannot resume a
  # half-built derivation anyway — crash salvage for in-flight compiles is
  # ccache's job (ccache.nix), not this mount's.
  #
  # The scratch partition is plain dm-crypt keyed from /dev/urandom on every
  # boot, matching the swap's security posture: build inputs/sources never hit
  # the platter in cleartext and nothing survives a reboot. tmp=ext4 makes
  # systemd-cryptsetup mkfs the mapping each boot, which is exactly right for
  # inherently throwaway build dirs (no manual formatting, ever).
  #
  # ext4, not XFS: XFS hard-caps symlink targets at 1024 bytes
  # (XFS_SYMLINK_MAXLEN — an on-disk format constant from the Irix era,
  # not a mkfs/mount-tunable; confirmed directly by creating symlinks on a
  # loopback XFS fs: 1023 bytes succeeds, 1024+ fails ENAMETOOLONG on every
  # kernel). Nix's own build-from-source hits this: nix-util-tests-run's
  # `readLinkAt.works` creates 2048- and 4095-byte symlink targets to
  # exercise readlinkat() buffer growth, and nixpkgs' pinned nix 2.34.8
  # predates upstream's fix (nix#f535e4a) that catches ENAMETOOLONG and
  # skips those sub-cases on filesystems that don't support long targets.
  # ext4 has no such ceiling (targets up to the full 4095-byte Linux
  # PATH_MAX-1), so this only ever surfaces on XFS/overlayfs. Loses XFS's
  # per-AG parallelism for the 32-thread build workload, but the
  # every-boot mkfs makes reverting free if that turns out to matter more
  # than losing an afternoon to filesystem-specific test breakage.
  #
  # The mapping is named "scratch" deliberately — no dash, so the systemd unit
  # is plain systemd-cryptsetup@scratch.service with no \x2d escaping needed.
  #
  # sector-size=4096 requires the partition SIZE to be a multiple of 8×512 B
  # sectors, or systemd-cryptsetup fails at boot with "Device size is not
  # aligned to requested sector size". sgdisk aligns partition starts only;
  # the partition must be created with `sgdisk --align-end` (-I) so the end
  # doesn't run to the disk's unaligned last usable sector.
  environment.etc.crypttab.text = ''
    scratch /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S73WNJ0TA08364H-part2 /dev/urandom plain,cipher=aes-xts-plain64,size=512,sector-size=4096,discard,tmp=ext4
  '';

  # Mount directly over the default build-dir location so no nix.settings
  # change is needed; the daemon keeps using its default path.
  fileSystems."/nix/var/nix/builds" = {
    device = "/dev/mapper/scratch";
    fsType = "ext4";
    options = [
      "noatime"
      "nodev"
      "nosuid"
      # The fstab generator only sees an opaque /dev/mapper device here, so
      # explicitly tie the mount to the cryptsetup unit that creates (and
      # mkfs's) it. Requires= + After= in one option.
      "x-systemd.requires=systemd-cryptsetup@scratch.service"
      "X-mount.mkdir"
    ];
  };
}
