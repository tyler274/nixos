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
  # the platter in cleartext and nothing survives a reboot. tmp=xfs makes
  # systemd-cryptsetup mkfs the mapping each boot, which is exactly right for
  # inherently throwaway build dirs (no manual formatting, ever). XFS over
  # ext4/btrfs: per-AG parallelism suits 32 build threads hammering
  # create/write/delete, with none of btrfs's CoW+checksum overhead — all
  # integrity machinery is wasted on data that never survives a reboot.
  # The every-boot mkfs makes the switch free (nothing to migrate).
  #
  # Known tradeoff: XFS hard-caps symlink targets at 1024 bytes
  # (XFS_SYMLINK_MAXLEN — an on-disk format constant from the Irix era,
  # not a mkfs/mount-tunable; confirmed directly on a loopback XFS fs:
  # 1023 bytes succeeds, 1024+ fails ENAMETOOLONG on every kernel). This
  # breaks nix-util-tests-run's `readLinkAt.works`, which creates 2048-
  # and 4095-byte symlink targets to exercise readlinkat() buffer growth.
  # nixpkgs' pinned nix 2.34.8 predates upstream's fix that catches
  # ENAMETOOLONG and skips those sub-cases on filesystems that don't
  # support long targets, so we disable the test ourselves for now — see
  # overlays/nix-fixes.nix. Revisit once nixpkgs picks up a nix release
  # with that upstream fix; the skip can be dropped then.
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
    scratch /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S73WNJ0TA08364H-part2 /dev/urandom plain,cipher=aes-xts-plain64,size=512,sector-size=4096,discard,tmp=xfs
  '';

  # Mount directly over the default build-dir location so no nix.settings
  # change is needed; the daemon keeps using its default path.
  fileSystems."/nix/var/nix/builds" = {
    device = "/dev/mapper/scratch";
    fsType = "xfs";
    options = [
      "noatime"
      "nodev"
      "nosuid"
      # Larger in-memory log buffers help the metadata-heavy unpack/delete
      # phases of builds.
      "logbsize=256k"
      # The fstab generator only sees an opaque /dev/mapper device here, so
      # explicitly tie the mount to the cryptsetup unit that creates (and
      # mkfs's) it. Requires= + After= in one option.
      "x-systemd.requires=systemd-cryptsetup@scratch.service"
      "X-mount.mkdir"
    ];
  };
}
