{ ... }:

{
  # NOTE: Nix >= 2.24 moved daemon build sandboxes from /tmp to
  # /nix/var/nix/builds, which now lives on the 980 PRO scratch partition
  # (../scratch.nix) — this dataset no longer sees them. It still keeps
  # everything ELSE that lands in /tmp off rpool/nixos/root (and therefore out
  # of every snapshot) while letting large files grow into whatever pool space
  # is free — a fixed-size tmpfs would kill those.
  # sync=disabled is safe for /tmp: the kernel's page cache is the durability
  # guarantee here, not ZFS intent-log.
  #
  # The dataset must be created once (mountpoint=legacy is REQUIRED — without
  # it ZFS auto-mounts the dataset itself and races the fileSystems entry below,
  # causing a double-mount conflict on boot):
  #   sudo zfs create -o mountpoint=legacy \
  #                   -o com.sun:auto-snapshot=false \
  #                   -o sync=disabled \
  #                   rpool/nixos/tmp
  #   sudo chmod 1777 /tmp   # world-writable sticky bit
  #
  # Verify properties are set correctly:
  #   zfs get mountpoint,com.sun:auto-snapshot,sync rpool/nixos/tmp
  fileSystems."/tmp" = {
    device = "rpool/nixos/tmp";
    fsType = "zfs";
    options = [
      # NO zfsutil here: mount.zfs refuses `-o zfsutil` on mountpoint=legacy
      # datasets (mount_zfs.c), so combining them fails the mount at boot.
      # Legacy datasets use plain `mount -t zfs`.
      "X-mount.mkdir"
      "noatime"
      "nodev"
      "nosuid"
      # mode=1777 is a tmpfs-only option; mount.zfs rejects it and fails the
      # mount. The sticky world-writable bit is set once on the dataset itself:
      #   sudo chmod 1777 /tmp
    ];
    # neededForBoot must stay false (the default). Setting it true moves the
    # mount into stage 1 and generates a sysroot-tmp.mount unit that tries to
    # mount rpool/nixos/tmp inside the initrd at /sysroot/tmp, before ZFS
    # userland is ready — causing the /sysroot/tmp boot error.
  };

  # Docker's zfs storage driver creates one dataset per image/container layer as
  # a child of whatever dataset holds /var/lib/docker. With the default data root
  # that dataset was rpool/nixos/var/lib, so every layer landed under the
  # snapshotted+replicated var tree and flooded sanoid, the generation-snapshot
  # activation script (zfs snapshot -r rpool/nixos@...), and syncoid with
  # hundreds of throwaway datasets and snapshots (they even got replicated to
  # local-backup).
  #
  # Give docker a dedicated dataset that lives OUTSIDE rpool/nixos so none of
  # those mechanisms can reach it:
  #   * the generation snapshot is `-r rpool/nixos`           -> rpool/docker is excluded
  #   * sanoid only configures the rpool/nixos/* trees        -> never sees it
  #   * syncoid's source is rpool/nixos                       -> never replicates it
  # rpool/docker is still encrypted (ZFS forces a child of an encrypted parent —
  # here the rpool encryption root — to inherit its key) and is tagged
  # com.sun:auto-snapshot=false for good measure.
  #
  # mountpoint=legacy on the dataset is REQUIRED for the same reason as /tmp
  # above: without it ZFS would auto-mount rpool/docker itself and race this
  # systemd mount (which, via RequiresMountsFor, correctly orders after the
  # /var/lib mount). The dataset must be created once:
  #   sudo zfs create -o mountpoint=legacy \
  #                   -o com.sun:auto-snapshot=false \
  #                   rpool/docker
  # See the one-time docker-storage migration steps committed alongside this
  # change for destroying the OLD per-layer datasets under rpool/nixos/var/lib
  # (and their replicas on local-backup) before switching over.
  fileSystems."/var/lib/docker" = {
    device = "rpool/docker";
    fsType = "zfs";
    options = [
      # NO zfsutil — legacy dataset, same reason as /tmp above.
      "X-mount.mkdir"
      "noatime"
    ];
  };

  # Game datasets mount via zfs-game-home-mounts.service after /home/luluco.
  # Do not add fileSystems entries here — nested children race the home mount.
}
