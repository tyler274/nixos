{ lib, ... }:

let
  cyreneZfs = import ./lib.nix { inherit lib; };
  inherit (cyreneZfs) gameHomeMounts;
in
{
  # Large, re-downloadable game data lives on dedicated ZFS children of the home
  # dataset, mounted at their ~/.local/share/* paths. Each is a normal fileSystems
  # entry using zfsutil (mount.zfs reads the dataset's own mountpoint property).
  #
  # Why this is enough — no custom service or activation script needed:
  #   * systemd auto-orders these mount units AFTER /home/luluco because the
  #     paths are nested, so the parent home dataset is always mounted first.
  #   * X-mount.mkdir creates the mountpoint directory if it does not exist.
  #   * nofail keeps a missing/again-empty dataset from blocking boot.
  #
  # One-time per dataset (already done for the existing ones; required for any
  # new launcher added to gameHomeMounts in lib.nix). canmount=noauto stops
  # zfs-mount.service from also mounting it and racing the systemd mount unit:
  #   sudo zfs create -o canmount=noauto \
  #                   -o com.sun:auto-snapshot=false \
  #                   -o mountpoint=<the ~/.local/share/* path> \
  #                   rpool/nixos/home/luluco/<name>
  # For an existing dataset, set the same properties instead of create:
  #   sudo zfs set canmount=noauto com.sun:auto-snapshot=false \
  #                mountpoint=<path> rpool/nixos/home/luluco/<name>
  fileSystems = lib.mapAttrs (_mountPoint: dataset: {
    device = dataset;
    fsType = "zfs";
    options = [
      "zfsutil"
      "X-mount.mkdir"
      "nofail"
    ];
  }) gameHomeMounts;

  # X-mount.mkdir creates any missing mountpoint path components as root:root,
  # and a freshly `zfs create`d dataset root is also root-owned. After a fresh
  # install this left ~/.local, ~/.local/share and every game mountpoint
  # unwritable by the user (Steam's bootstrap then dies with "Permission
  # denied" extracting bootstraplinux_ubuntu12_32.tar.xz). These rules run at
  # boot after local-fs.target and again during nixos-rebuild activation, so
  # the mounted dataset roots (ownership persists in the dataset) and the
  # intermediate directories on the home dataset always end up user-owned.
  systemd.tmpfiles.rules = [
    "d /home/luluco/.local 0755 luluco users -"
    "d /home/luluco/.local/share 0755 luluco users -"
  ]
  ++ map (mountPoint: "d ${mountPoint} 0755 luluco users -") (lib.attrNames gameHomeMounts);
}
