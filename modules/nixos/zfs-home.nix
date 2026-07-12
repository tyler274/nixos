{ config, lib, pkgs, ... }:

let
  cfg = config.zfsHome;

  datasetFor = name: "${cfg.poolName}/nixos/home/${name}";

  # Build a name→home attrset from the explicit users list to avoid
  # reading config.users.users inside fileSystems, which causes an
  # infinite recursion through: fileSystems → boot.supportedFilesystems
  # → services.rpcbind.enable (nfs.nix) → users.users → fileSystems.
  managedUsers = lib.genAttrs cfg.users (name: {
    home = "/home/${name}";
  });
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

    primaryGroup = lib.mkOption {
      type        = lib.types.str;
      default     = "users";
      description = "Primary group assigned to each newly created home directory.";
    };

    homeMode = lib.mkOption {
      type        = lib.types.str;
      default     = "700";
      description = "Permission bits applied to each newly created home directory.";
    };

    users = lib.mkOption {
      type        = lib.types.listOf lib.types.str;
      default     = [];
      description = ''
        Usernames to manage ZFS home datasets for. Each user is expected
        to have their home directory under /home/<username>.

        This must be set explicitly rather than auto-detected from
        users.users to avoid an infinite recursion in the NixOS module
        system (fileSystems → boot.supportedFilesystems → rpcbind →
        users.users → fileSystems).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Derive one fileSystems entry per managed user at evaluation time so
    # systemd knows about the mount before any user session starts.
    fileSystems = lib.mapAttrs' (name: u:
      lib.nameValuePair u.home {
        device  = datasetFor name;
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
            # canmount=noauto: the systemd mount unit generated from fileSystems
            # is the single mounter; letting zfs-mount.service also auto-mount
            # the dataset races it and fails the boot-critical /home/<user>
            # mount with "filesystem already mounted".
            ${pkgs.zfs}/bin/zfs create \
              -o canmount=noauto \
              -o mountpoint=${lib.escapeShellArg u.home} \
              ${lib.escapeShellArg dataset} \
            && ${pkgs.zfs}/bin/zfs set \
              quota=${lib.escapeShellArg cfg.defaultQuota} \
              ${lib.escapeShellArg dataset} \
            && chown ${lib.escapeShellArg name}:${lib.escapeShellArg cfg.primaryGroup} \
              ${lib.escapeShellArg u.home} \
            && chmod ${lib.escapeShellArg cfg.homeMode} \
              ${lib.escapeShellArg u.home} \
            || true
          fi
        ''
      ) managedUsers);
    };
  };
}
