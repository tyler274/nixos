{
  config,
  pkgs,
  lib,
  ...
}:

let
  cyreneZfs = import ./lib.nix { inherit lib; };
  inherit (cyreneZfs) nixosSnapshotRetentionDays unsnapshottedHomeDatasets;
  # `zfs snapshot -r` cannot exclude children, so drop the new snapshot on
  # rebuildable datasets right after taking it; otherwise it pins deleted
  # games, caches and /tmp for the whole retention window.
  noGenerationSnapshot = [ "rpool/nixos/tmp" ] ++ unsnapshottedHomeDatasets;
  dockerZfsCleanup = pkgs.writeShellApplication {
    name = "docker-zfs-cleanup";
    runtimeInputs = [ config.virtualisation.docker.package config.boot.zfs.package pkgs.util-linux ];
    text = ''
      exec flock --nonblock /run/lock/docker-zfs-cleanup.lock \
        ${pkgs.python3}/bin/python3 ${./docker-zfs-cleanup.py} "$@"
    '';
  };
in
{
  services.zfs = {
    autoScrub = {
      enable = true;
      # A scrub reads every block of every pool; weekly is enough on NVMe.
      interval = "weekly";
    };
    trim = {
      enable = true;
      interval = "daily";
    };
  };

  # Prune through Docker, which knows which objects are still referenced.
  # This does not remove datasets orphaned by the former ZFS storage driver.
  # Keep all volumes and give unused images/stopped containers a week's grace.
  virtualisation.docker.autoPrune = lib.mkIf config.virtualisation.docker.enable {
    enable = true;
    dates = "daily";
    persistent = true;
    randomizedDelaySec = "30min";
    flags = [ "--all" "--filter=until=168h" ];
    allVolumes.enable = false;
  };

  environment.systemPackages = lib.optional config.virtualisation.docker.enable dockerZfsCleanup;
  systemd.services.docker-zfs-cleanup = lib.mkIf config.virtualisation.docker.enable {
    description = "Remove retired Docker ZFS layers after migration to overlay2";
    after = [ "docker.service" ];
    requisite = [ "docker.service" ];
    unitConfig.RequiresMountsFor = "/var/lib/docker";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${dockerZfsCleanup}/bin/docker-zfs-cleanup --apply";
      TimeoutStartSec = "1h";
      Nice = 19;
    };
  };
  systemd.timers.docker-zfs-cleanup = lib.mkIf config.virtualisation.docker.enable {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30min";
    };
  };

  # Take a recursive rpool snapshot on every nixos-rebuild switch so each
  # generation has a matching ZFS checkpoint for block-level rollback.
  system.activationScripts.zfs-generation-snapshot = {
    supportsDryActivation = false;
    text = ''
      ts=$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)
      ${pkgs.zfs}/bin/zfs snapshot -r rpool/nixos@nixos-$ts 2>/dev/null || true
      for ds in ${lib.escapeShellArgs noGenerationSnapshot}; do
        ${pkgs.zfs}/bin/zfs destroy "$ds@nixos-$ts" 2>/dev/null || true
      done

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
      # Snapshot pruning can't free build output or caches, so warn early
      # enough to clean those by hand (journalctl -p warning). agents holds
      # the build roots and is absent until agents-pool.service imports it.
      for pool in rpool agents; do
        cap=$(${pkgs.zfs}/bin/zpool list -Hpo capacity "$pool" 2>/dev/null) || continue
        if [ "$cap" -ge 80 ]; then
          echo "<4>$pool at ''${cap}% capacity: clear build output (/tmp/coda-target-*, build roots, target/)"
        fi
      done
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
