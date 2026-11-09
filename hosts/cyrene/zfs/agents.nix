{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.cyrene.agentsPool;
in
{
  # Pool `agents` holds the ccache and the sandboxed Coda agent and CI trees.
  # It must never be able to delay or fail boot, so it is NOT in
  # boot.zfs.extraPools (that adds a 60s-retry import unit that every mount on
  # the pool requires, and would not load the agents/coda key anyway) and has
  # no fileSystems entries. One late unit imports, unlocks and mounts it after
  # boot instead. If the disk or the key is missing, only this unit and the
  # units that require it (the sandbox containers) fail.
  #
  # Datasets use real mountpoints, not legacy, so `zfs mount` places them.
  # cachefile=none keeps any other import path from picking the pool up early.
  #
  # One-time creation (destroys whatever is on the disk):
  #   disk=<cfg.disk>; key=<cfg.keyFile>
  #   sudo wipefs -a "$disk"-part1; sudo sgdisk --zap-all "$disk"
  #   sudo zpool create -o ashift=12 -o autotrim=on -o cachefile=none \
  #     -O compression=zstd -O atime=off -O xattr=sa -O acltype=posix \
  #     -O mountpoint=none -O canmount=off agents "$disk"
  #   sudo zfs create -o mountpoint=/var/cache/ccache agents/ccache
  #   sudo install -d -m 0700 "$(dirname "$key")"
  #   sudo dd if=/dev/urandom of="$key" bs=32 count=1; sudo chmod 0400 "$key"
  #   sudo zfs create -o encryption=aes-256-gcm -o keyformat=raw \
  #     -o keylocation=file://"$key" -o canmount=off -o mountpoint=none agents/coda
  #   for d in src build ci; do sudo zfs create -o mountpoint=/agents/coda/$d agents/coda/$d; done
  # Back the key file up offline; without it agents/coda is unreadable.
  options.cyrene.agentsPool = {
    enable = lib.mkEnableOption "the post-boot import of the agents ZFS pool";
    disk = lib.mkOption {
      type = lib.types.str;
      description = "Stable path of the pool's only disk; the import is skipped while it is absent.";
    };
    keyFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/zfs/keys/agents-coda.key";
      description = "Raw key for agents/coda, stored on the root pool.";
    };
    mounts = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        "agents/coda/src" = "/agents/coda/src";
        "agents/coda/build" = "/agents/coda/build";
        "agents/coda/ci" = "/agents/coda/ci";
      };
      description = "Datasets that must be mounted at these paths before the pool counts as ready.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.agents-pool = {
      description = "Import, unlock and mount the agents ZFS pool";
      wantedBy = [ "multi-user.target" ];
      after = [
        "zfs-import.target"
        "zfs-mount.service"
        "local-fs.target"
      ];
      unitConfig.ConditionPathExists = cfg.disk;
      path = [
        config.boot.zfs.package
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "90s";
      };
      script = ''
        if ! zpool list -H agents >/dev/null 2>&1; then
          zpool import -N -d "$(dirname ${cfg.disk})" -o cachefile=none agents
        fi
        if [ "$(zfs get -H -o value keystatus agents/coda)" != available ]; then
          zfs load-key -L file://${cfg.keyFile} agents/coda
        fi
        ${lib.concatStrings (
          lib.mapAttrsToList (dataset: mountpoint: ''
            if [ "$(findmnt -rn -M ${mountpoint} -o SOURCE)" != ${dataset} ]; then
              zfs mount ${dataset}
            fi
            test "$(findmnt -rn -M ${mountpoint} -o SOURCE)" = ${dataset}
          '') cfg.mounts
        )}
      '';
    };
  };
}
