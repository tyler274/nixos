# Shared Cyrene ZFS constants (not a NixOS module — import from sibling files).
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
  # 30 days of snapshots, matching the nix.gc --delete-older-than 30d window so
  # every live Nix generation has a corresponding ZFS checkpoint available.
  # nixos generation snapshots (@nixos-*) are pruned separately in maintenance.nix.
  snapshotRetention = {
    hourly = 72;
    daily = 30;
    monthly = 0;
    yearly = 0;
  };
  nixosSnapshotRetentionDays = 30;

  inherit gameHomeMounts;
  gameHomeDatasets = lib.unique (lib.attrValues gameHomeMounts);
}
