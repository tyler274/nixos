{
  lib,
  ...
}:

let
  cyreneZfs = import ./lib.nix { inherit lib; };
  inherit (cyreneZfs)
    snapshotRetention
    gameHomeDatasets
    agentsPoolCreated
    ;

  gameDatasetSanoidEntries = lib.genAttrs gameHomeDatasets (_: {
    autosnap = false;
    autoprune = false;
  });

  # Agent worktrees are snapshotted so a bad agent edit can be rolled back.
  # Build output, CI scratch and ccache are rebuildable churn and are not.
  # While the pool is absent sanoid only warns about these, and the module's
  # `zfs allow` pre-steps are failure-tolerant, so rpool snapshots still run.
  agentsSanoidEntries = lib.optionalAttrs agentsPoolCreated {
    "agents/coda/src" = {
      autosnap = true;
      autoprune = true;
      hourly = 48;
      daily = 14;
      monthly = 0;
      yearly = 0;
    };
  }
  // lib.optionalAttrs agentsPoolCreated (
    lib.genAttrs [ "agents/ccache" "agents/coda/build" "agents/coda/ci" ] (_: {
      autosnap = false;
      autoprune = false;
    })
  );
in
{
  services.sanoid = {
    enable = true;
    interval = "hourly";

    datasets = gameDatasetSanoidEntries // agentsSanoidEntries // {
      # Home: longer retention; recursive covers all per-user sub-datasets
      # automatically - no per-user entry needed when new users are added.
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
