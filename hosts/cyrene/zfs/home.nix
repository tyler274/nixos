{ ... }:

{
  zfsHome = {
    enable = true;
    poolName = "rpool";
    defaultQuota = "500G";
    # Covers luluco's whole tree (home, the game datasets, their snapshots) so
    # it can't fill rpool and starve /nix, /tmp, /var and docker. Must stay
    # above current usage (2.76T on 2026-11-19) or activation re-locks the
    # home dataset (full home = no login). rpool is 3.59T; 2.9T leaves ~150G
    # of pool headroom for the system.
    quotas.luluco = "2.9T";
    users = [
      "luluco"
      "phainon"
    ];
  };

  users.users.root.initialHashedPassword = "$6$31uKiv3HbrCU2pbC$D9qnquW32p.8cZH5yz.7j5ExFywS.6j2gii.bqZIRDj551HI2WO5yUiMsUUg0nP.KAXWtSEOj0.VWsXt0uAqt1";
}
