{
  lib,
  ...
}:

let
  cyreneZfs = import ./lib.nix { inherit lib; };
  inherit (cyreneZfs)
    snapshotRetention
    gameHomeDatasets
    ;

  gameDatasetSanoidEntries = lib.genAttrs gameHomeDatasets (_: {
    autosnap = false;
    autoprune = false;
  });
in
{
  services.sanoid = {
    enable = true;
    interval = "hourly";

    datasets = gameDatasetSanoidEntries // {
      # Home: longer retention; recursive covers all per-user sub-datasets
      # automatically — no per-user entry needed when new users are added.
      "rpool/nixos/home" = {
        autoprune = true;
        autosnap = true;
        inherit (snapshotRetention)
          hourly
          daily
          monthly
          yearly
          ;
        recursive = true;
      };

      "rpool/nixos/tmp" = {
        autosnap = false;
        autoprune = false;
      };

      "rpool/nixos/root" = {
        autoprune = true;
        autosnap = true;
        inherit (snapshotRetention)
          hourly
          daily
          monthly
          yearly
          ;
      };

      "rpool/nixos/var" = {
        autoprune = true;
        autosnap = true;
        inherit (snapshotRetention)
          hourly
          daily
          monthly
          yearly
          ;
        recursive = true;
      };
    };
  };
}
