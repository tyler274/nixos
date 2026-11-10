# Shared Cyrene ZFS constants (not a NixOS module - import from sibling files).
{ lib }:

let
  gameHomeMounts = {
    "/home/luluco/.local/share/Steam" = "rpool/nixos/home/luluco/steam";
    "/home/luluco/.local/share/anime-game-launcher" = "rpool/nixos/home/luluco/anime-game-launcher";
    "/home/luluco/.local/share/honkers-railway-launcher" =
      "rpool/nixos/home/luluco/honkers-railway-launcher";
    "/home/luluco/.local/share/sleepy-launcher" = "rpool/nixos/home/luluco/sleepy-launcher";
    "/home/luluco/.local/share/wavey-launcher" = "rpool/nixos/home/luluco/wavey-launcher";
  };
in
{
  # 2 weeks of snapshots, matching the nix.gc --delete-older-than 14d window so
  # every live Nix generation has a corresponding ZFS checkpoint available.
  # nixos generation snapshots (@nixos-*) are pruned separately in maintenance.nix.
  snapshotRetention = {
    hourly = 72;
    daily = 14;
    monthly = 0;
    yearly = 0;
  };
  nixosSnapshotRetentionDays = 14;

  inherit gameHomeMounts;
  gameHomeDatasets = lib.unique (lib.attrValues gameHomeMounts);

  # The local-backup pool's disk is currently detached. This gates the pool
  # import (boot.nix) and the syncoid replication into it (syncoid.nix):
  # importing a missing pool retries for 60s and stalls every boot. Flip back
  # to true once the disk is reattached, then run once:
  #   sudo zpool import -f local-backup
  localBackupAttached = false;

  # Whether the `agents` pool exists on the 980 PRO (see agents.nix). While
  # false, the 980 PRO stays the XFS ccache disk and nothing references the
  # pool. Flip to true only after the one-time creation in agents.nix, then
  # activate with `nixos-rebuild switch` (not `boot`) so a mistake shows up
  # immediately instead of on the next boot.
  agentsPoolCreated = true;
}
