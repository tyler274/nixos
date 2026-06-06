{ pkgs, lib, ... }:

# Samsung PSSD T7 Shield — external USB SSD used as Steam game library.
#
# Mount tuning rationale:
#   noatime        — eliminates atime writes on every file read; games read
#                    constantly so this removes significant write amplification
#   compress=zstd:1 — level 1 is near-free CPU cost; uncompressed game assets
#                    (textures, audio, maps) compress well; already-packed files
#                    (.pak, .zip) are detected and skipped automatically
#   autodefrag     — Steam's VDF files, SQLite databases, and shader-cache
#                    indexes are small files CoW-fragmented on every update;
#                    autodefrag coalesces them in the background
#   ssd            — enables SSD-aware chunk allocator (also auto-detected from
#                    ROTA=0, kept explicit for clarity)
#   space_cache=v2 — modern free-space tree, substantially faster than v1 on
#                    large volumes; v1 is the kernel default before 6.x
#   nofail                      — USB drive may not be attached at boot; do not
#                                  block the boot sequence if it is absent
#   x-systemd.device-timeout=5s — give udev 5 s to find the device; after that
#                                  nofail lets the mount unit finish as skipped
#
# TRIM is intentionally omitted: DISC-MAX=0 on this USB bridge means the kernel
# cannot pass discard commands through to the NVMe controller, so discard=async
# would be silently ignored.
#
# Shader-cache nodatacow:
#   The steamapps/shadercache directory benefits from disabling Copy-on-Write
#   because it consists of many small files rewritten in-place constantly (no
#   snapshot value, just write amplification from CoW extents).  nodatacow is
#   a btrfs inode flag (chattr +C) set once on the directory; all new inodes
#   inside inherit it.  A systemd oneshot service applies it after the mount.

{
  fileSystems."/mnt/steam" = {
    device = "/dev/disk/by-id/usb-Samsung_PSSD_T7_Shield_S6SFNJ0WA37378H-0:0-part1";
    fsType = "btrfs";
    options = [
      "noatime"
      "compress=zstd:1"
      "autodefrag"
      "ssd"
      "space_cache=v2"
      "nofail"
      "x-systemd.device-timeout=5s"
    ];
  };

  # Set nodatacow on the shader cache directory after every mount so that
  # Steam's constant small overwrites don't accumulate as CoW extents.
  # Path: /mnt/steam/SteamLibrary/steamapps/shadercache
  # The flag is persistent on the inode; this service is idempotent.
  systemd.services.steam-usb-nodatacow = {
    description = "Set nodatacow on Steam shader cache (T7 Shield)";
    wantedBy = [ "mnt-steam.mount" ];
    after = [ "mnt-steam.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      dir=/mnt/steam/SteamLibrary/steamapps/shadercache
      ${pkgs.coreutils}/bin/mkdir -p "$dir"
      # chattr +C is a no-op if the flag is already set.
      ${pkgs.e2fsprogs}/bin/chattr +C "$dir"
    '';
  };
}
