{ config, lib, pkgs, ... }:

let
  cfg = config.zfsHome;

  managedUsers = lib.filterAttrs (_: u:
    u.isNormalUser && lib.hasPrefix "/home/" u.home
  ) config.users.users;

  datasetFor = name: "${cfg.poolName}/nixos/home/${name}";
in
{
  options.zfsHome = {
    enable = lib.mkEnableOption "automatic ZFS home dataset management";

    poolName = lib.mkOption {
      type        = lib.types.str;
      default     = "rpool";
      description = "ZFS pool that contains the nixos/home hierarchy.";
    };

    defaultQuota = lib.mkOption {
      type        = lib.types.str;
      default     = "500G";
      description = "Quota applied to each newly created user dataset.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Derive one fileSystems entry per managed user at evaluation time so
    # systemd knows about the mount before any user session starts.
    fileSystems = lib.mapAttrs' (_: u:
      let username = lib.last (lib.splitString "/" u.home); in
      lib.nameValuePair u.home {
        device  = datasetFor username;
        fsType  = "zfs";
        options = [ "zfsutil" "X-mount.mkdir" ];
      }
    ) managedUsers;

    # Idempotently create any missing user dataset during activation.
    # Runs after the 'users' script so the UID exists before we chown.
    system.activationScripts.zfs-home-datasets = {
      deps = [ "users" ];
      text = lib.concatStrings (lib.mapAttrsToList (name: u:
        let dataset = datasetFor name; in
        ''
          if ! ${pkgs.zfs}/bin/zfs list -H -o name ${lib.escapeShellArg dataset} &>/dev/null; then
            echo "zfs-home: creating ${dataset}"
            ${pkgs.zfs}/bin/zfs create \
              -o canmount=on \
              -o mountpoint=${lib.escapeShellArg u.home} \
              ${lib.escapeShellArg dataset} \
            && ${pkgs.zfs}/bin/zfs set \
              quota=${lib.escapeShellArg cfg.defaultQuota} \
              ${lib.escapeShellArg dataset} \
            || true
          fi
        ''
      ) managedUsers);
    };
  };
}
