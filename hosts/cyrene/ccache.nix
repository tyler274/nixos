{ ... }:

{
  # Persistent compiler cache on the Samsung 980 PRO (single partition; it
  # handed swap+scratch duty to the 990 PRO — see scratch.nix/default.nix).
  #
  # Purpose: crash insurance for the from-source znver5 world build. Completed
  # derivations already survive any crash (they're registered into /nix/store
  # on rpool), and Nix can never resume a half-built derivation, so the only
  # crash exposure is a multi-hour compile restarting from zero. ccache writes
  # each object file to this cache as it compiles, so a restarted build
  # fast-forwards through everything compiled before the crash. The same
  # mechanism also covers the recurring "compiled for hours, failed in
  # checkPhase, fixed via disabledTests override, recompiles identically"
  # loop (znver5-fixes.nix is full of those).
  #
  # Deliberately NOT wrapping the whole world in ccacheStdenv: that would
  # change every derivation hash (one extra full world rebuild), and the
  # steady-state hit rate for dependency-cascade rebuilds is poor anyway
  # (compile lines embed dependency store paths, which change with every
  # upstream fix). Only the multi-hour monsters below are wrapped — they're
  # where all the crash exposure is concentrated.
  #
  # Unencrypted on purpose, unlike swap/scratch: it only ever holds object
  # code compiled from public nixpkgs sources, and encrypting it with an
  # ephemeral urandom key would defeat persistence — the whole point.
  #
  # One-time setup after the role-swap reboot (the 980 is idle then):
  #   sudo sgdisk --zap-all -I -n 1:0:0 -t 1:8300 -c 1:ccache \
  #     /dev/disk/by-id/nvme-Samsung_SSD_980_PRO_2TB_S6B0NL0TA08502B
  #   sudo mkfs.xfs -L ccache \
  #     /dev/disk/by-id/nvme-Samsung_SSD_980_PRO_2TB_S6B0NL0TA08502B-part1
  #   sudo mount /var/cache/ccache
  #   sudo chown root:nixbld /var/cache/ccache && sudo chmod 770 /var/cache/ccache
  #   echo 'max_size = 400G' | sudo tee /var/cache/ccache/ccache.conf
  # XFS to match the scratch mount (scratch.nix) — the small-object cache
  # workload is indifferent between xfs/ext4, so keep a single filesystem
  # type in play across both NVMe roles.
  fileSystems."/var/cache/ccache" = {
    device = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_2TB_S6B0NL0TA08502B-part1";
    fsType = "xfs";
    options = [
      "noatime"
      "nodev"
      "nosuid"
      # The filesystem is created manually once (steps above); don't hang
      # boot while it doesn't exist yet. Until it's mounted, tmpfiles still
      # creates the plain directory, so wrapped builds keep working (cache
      # just lands on rpool temporarily).
      "nofail"
      "X-mount.mkdir"
    ];
  };

  programs.ccache = {
    enable = true;
    cacheDir = "/var/cache/ccache";
    # Wrapped with ccacheStdenv via the module's overlay; only top-level
    # attrs work here. Wrapping changes these packages' hashes (one-time
    # rebuild of them and their dependents). chromium is intentionally
    # absent: its build uses a custom clang stdenv that a plain stdenv
    # override doesn't reach — revisit if it starts flaking after long
    # compiles.
    packageNames = [ "firefox-unwrapped" ];
  };

  # qtwebengine (the other multi-hour monster) lives in the qt6Packages
  # scope, out of packageNames' top-level reach; wrap it by hand.
  nixpkgs.overlays = [
    (final: prev: {
      qt6Packages = prev.qt6Packages.overrideScope (
        qFinal: qPrev: {
          qtwebengine = qPrev.qtwebengine.override { stdenv = final.ccacheStdenv; };
        }
      );
    })
  ];

  # No extra-sandbox-paths needed: programs.ccache already exposes cacheDir
  # to the build sandbox (verified in the evaluated nix.settings).
}
