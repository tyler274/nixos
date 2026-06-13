{
  pkgs,
  lib,
  ...
}:

let
  cyreneZfs = import ./lib.nix { inherit lib; };
  inherit (cyreneZfs) nixosSnapshotRetentionDays;
in
{
  services.zfs = {
    autoScrub = {
      enable = true;
      interval = "daily";
    };
    trim = {
      enable = true;
      interval = "daily";
    };
  };

  # Take a recursive rpool snapshot on every nixos-rebuild switch so each
  # generation has a matching ZFS checkpoint for block-level rollback.
  system.activationScripts.zfs-generation-snapshot = {
    supportsDryActivation = false;
    text = ''
      ts=$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)
      ${pkgs.zfs}/bin/zfs snapshot -r rpool/nixos@nixos-$ts 2>/dev/null || true

      cutoff=$(${pkgs.coreutils}/bin/date -d "${toString nixosSnapshotRetentionDays} days ago" +%Y%m%d)
      while IFS= read -r snap; do
        case "$snap" in
          *@nixos-*)
            snap_date=''${snap##*@nixos-}
            snap_date=''${snap_date%%-*}
            if [ "''${#snap_date}" -eq 8 ] && [ "$snap_date" -lt "$cutoff" ]; then
              ${pkgs.zfs}/bin/zfs destroy "$snap" 2>/dev/null || true
            fi
            ;;
        esac
      done < <(${pkgs.zfs}/bin/zfs list -H -t snapshot -o name -r rpool/nixos 2>/dev/null)
    '';
  };

  # Prune sanoid-managed snapshots when rpool is nearly full, without waiting
  # for the hourly sanoid timer.
  systemd.services.zfs-prune-on-pressure = {
    description = "Prune ZFS snapshots when rpool usage exceeds threshold";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    script = ''
      USED=$(${pkgs.zfs}/bin/zpool list -Hpo capacity rpool)
      if [ "$USED" -ge 85 ]; then
        echo "rpool at ''${USED}% capacity, pruning snapshots..."
        ${pkgs.sanoid}/bin/sanoid --prune-snapshots --verbose
      else
        echo "rpool at ''${USED}%, no pruning needed."
      fi
    '';
  };
  systemd.timers.zfs-prune-on-pressure = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "15min";
      RandomizedDelaySec = "2min";
    };
  };
}
