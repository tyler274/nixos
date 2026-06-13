{
  pkgs,
  lib,
  ...
}:

let
  cyreneZfs = import ./lib.nix { inherit lib; };
  inherit (cyreneZfs) gameHomeDatasets;

  gameDatasetSyncoidExcludes = map (dataset: "--exclude-datasets=${dataset}") gameHomeDatasets;
in
{
  services.syncoid = {
    enable = true;
    sshKey = "/etc/syncoid/.ssh/id_rsa";
    localSourceAllow = [
      "change-key"
      "compression"
      "create"
      "mount"
      "mountpoint"
      "receive"
      "rollback"
      "bookmark"
      "hold"
      "release"
      "send"
      "snapshot"
      "destroy"
    ];
    localTargetAllow = [
      "change-key"
      "compression"
      "create"
      "mount"
      "mountpoint"
      "receive"
      "rollback"
      "bookmark"
      "hold"
      "release"
      "send"
      "snapshot"
      "destroy"
    ];
    commonArgs = [
      ''--sshoption="UserKnownHostsFile=/etc/syncoid/.ssh/known_hosts"''
      "--compress=zstd-fast"
      "--recursive"
      # NOTE: do NOT put --sendoptions here. The NixOS syncoid module always
      # appends its own `--sendoptions <value>` at the end of the command, so
      # any --sendoptions in commonArgs would be silently overridden (Getopt
      # last-value-wins). Set sendOptions per-command instead.
    ];
    # Remote replication to rsync.net is pending SSH setup (the key at
    # /etc/syncoid/.ssh/id_rsa does not exist yet and the host is unreachable).
    # Leave it disabled until the key/known_hosts are provisioned, otherwise its
    # ExecStopPost `zfs unallow` races the local job and revokes the shared
    # rpool/nixos send/snapshot permissions mid-run ("permission denied").
    #
    # If local-backup replication is broken (pool full, stale syncoid holds, or
    # a diverged incremental chain), recover with:
    #   sudo zfs holds -r rpool/nixos
    #   sudo zfs release syncoid <snapshot>   # repeat for each stale hold
    #   sudo sanoid --prune-snapshots --verbose
    #   sudo zfs destroy -r local-backup/cyrene/rpool/nixos
    #   sudo systemctl start syncoid-local-target-init.service
    #   sudo systemctl start syncoid-rpool-nixos-local.service
    # commands."rpool/nixos" = {
    #   source = "rpool/nixos";
    #   target = "syncoid@zh2883b.rsync.net:data1/Cyrene/rpool/nixos";
    #   sendOptions = "w";
    #   extraArgs = [ "--use-hold" ];
    # };
    commands."rpool/nixos-local" = {
      source = "rpool/nixos";
      target = "local-backup/cyrene/rpool/nixos";
      # Raw send preserves the on-disk encrypted blocks; the local-backup pool
      # never needs to hold or know the encryption key.
      sendOptions = "w";
      # Place a ZFS hold on the last-sent source snapshot so sanoid's autoprune
      # cannot delete it between syncoid runs. Without this, sanoid could prune
      # the anchor snapshot and force a full resend on the next run. The hold is
      # released automatically after the next successful incremental send.
      extraArgs = [
        "--use-hold"
        # rpool/nixos/tmp is a no-snapshot build-sandbox dataset; there is
        # nothing worth backing up there and it could be enormous mid-build.
        "--exclude-datasets=rpool/nixos/tmp"
      ]
      ++ gameDatasetSyncoidExcludes
      ++ [
        # Docker uses the ZFS storage driver (virtualisation.docker.storageDriver
        # = "zfs") rooted at the rpool/nixos/var/lib dataset, so every image
        # layer and container is an ephemeral child dataset there: 64-hex layer
        # IDs, "<id>-init" container layers, and 25-char container IDs. Raw
        # replication with --use-hold places a ZFS hold on each one's snapshot,
        # which then blocks `docker rm`/`docker rmi` ("cannot destroy snapshot
        # ... it's being held") until the next syncoid run. They are fully
        # rebuildable, so skip them entirely. The regex matches any child of
        # var/lib whose name is a 25+-char run of [a-z0-9] (all three docker
        # dataset name forms) while still backing up the var/lib dataset itself
        # and any normally-named child datasets.
        "--exclude-datasets=rpool/nixos/var/lib/[a-z0-9]{25,}"
      ];
    };
  };

  # The syncoid NixOS module only delegates ZFS permissions on the *target* if
  # that dataset (or its parent) already exists; otherwise the zfs-allow
  # pre-hook is a silently-ignored no-op and the actual `zfs receive` fails with
  # "permission denied". The local-backup pool is only imported by this config
  # (boot.zfs.extraPools), never provisioned, so create the container datasets
  # that hold the backup before syncoid runs. canmount=off/mountpoint=none keeps
  # these intermediate containers from mounting anywhere; the received
  # rpool/nixos tree carries its own (raw, encrypted) properties.
  systemd.services.syncoid-local-target-init = {
    description = "Create local-backup container datasets for syncoid";
    after = [ "zfs-import.target" ];
    requiredBy = [ "syncoid-rpool-nixos-local.service" ];
    before = [ "syncoid-rpool-nixos-local.service" ];
    path = [ pkgs.zfs ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for ds in local-backup/cyrene local-backup/cyrene/rpool; do
        if ! zfs list -H "$ds" >/dev/null 2>&1; then
          zfs create -o canmount=off -o mountpoint=none "$ds"
        fi
      done
    '';
  };
}
