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
  # Offload them to the Samsung 980 PRO, which is split:
  #   part1: 512 GiB swap  (randomEncryption — see swapDevices in default.nix)
  #   part2: ~1.3 TiB Nix build scratch (this file)
  #
  # The scratch partition is plain dm-crypt keyed from /dev/urandom on every
  # boot, matching the swap's security posture: build inputs/sources never hit
  # the platter in cleartext and nothing survives a reboot. tmp=ext4 makes
  # systemd-cryptsetup mkfs the mapping each boot, which is exactly right for
  # inherently throwaway build dirs (no manual formatting, ever).
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
    scratch /dev/disk/by-id/nvme-Samsung_SSD_980_PRO_2TB_S6B0NL0TA08502B-part2 /dev/urandom plain,cipher=aes-xts-plain64,size=512,sector-size=4096,discard,tmp=ext4
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
