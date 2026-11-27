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

  # No root password hash here: this repo is public, and a committed hash can
  # be cracked offline. nixos-install prompts for one; change it with passwd.
}
