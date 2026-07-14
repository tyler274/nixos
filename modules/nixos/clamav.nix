{
  config,
  lib,
  ...
}:

let
  # Downloads directories of human users are the highest-risk write paths on a
  # desktop (browser downloads, torrent drops), so they get on-access scanning.
  # Derived from users.users so new hosts/accounts are covered automatically.
  normalUsers = lib.filterAttrs (_: u: u.isNormalUser) config.users.users;
  downloadDirs = lib.mapAttrsToList (_: u: "${u.home}/Downloads") normalUsers;
in
{
  services.clamav = {
    daemon = {
      enable = true;
      settings = {
        # Timestamped, detailed detection logging for post-incident forensics.
        LogTime = true;
        ExtendedDetectionInfo = true;

        # Also flag Potentially Unwanted Applications (adware, cracked-software
        # droppers, miners). Noisier, but detections are labelled PUA.* so they
        # are easy to distinguish from real malware.
        DetectPUA = true;

        # Raise scan ceilings so large downloads are actually scanned instead
        # of silently skipped (upstream defaults: 100M scan / 25M file), and
        # alert when something still exceeds them rather than staying quiet.
        MaxScanSize = "1024M";
        MaxFileSize = "512M";
        MaxRecursion = 20;
        AlertExceedsMax = true;

        # Never descend into these from a scheduled clamdscan run: the nix
        # store is immutable and huge, docker layers and Steam libraries are
        # enormous and low-risk, and pseudo-filesystems are meaningless.
        ExcludePath = [
          "^/nix/store/"
          "^/proc/"
          "^/sys/"
          "^/dev/"
          "^/var/lib/docker/"
          "^/home/[^/]+/\\.steam/"
          "^/home/[^/]+/\\.local/share/Steam/"
        ];

        # On-access scanning of Downloads: block the file open until the scan
        # verdict is in (Prevention), and pro-actively scan files as they are
        # created/moved into the watched dirs (ExtraScanning). If the open()
        # latency on large files ever becomes annoying, drop Prevention first.
        OnAccessPrevention = true;
        OnAccessExtraScanning = true;
        OnAccessIncludePath = downloadDirs;
      };
    };

    # Root-side fanotify listener that feeds the daemon; requires the include
    # paths above to exist at start (tmpfiles rule below guarantees that).
    clamonacc.enable = true;

    updater = {
      enable = true;
      interval = "hourly";
      frequency = 12;
      settings = {
        # Hot-reload clamd after each successful signature update instead of
        # waiting for its ~10 min SelfCheck cycle to notice the new database.
        NotifyClamd = "/etc/clamav/clamd.conf";
      };
    };

    # Fangfrisch pulls third-party signature feeds that the official freshclam
    # mirrors don't carry. Sanesecurity (phishing/spam/macro sigs) and URLhaus
    # (active malware-distribution URLs) are free and enabled by default; kept
    # explicit here so it's obvious what this host consumes. SecuriteInfo and
    # MalwarePatrol offer more feeds but require (free/paid) registration —
    # add customer_id/receipt settings here if that's ever wanted.
    fangfrisch = {
      enable = true;
      interval = "hourly";
      settings = {
        sanesecurity.enabled = "yes";
        urlhaus.enabled = "yes";
        urlhaus.max_size = "2MB";
      };
    };

    # Weekly sweep of the mutable parts of the system. On-access already covers
    # the hot path (Downloads); this catches anything that arrived some other
    # way. Saturday 03:00 to stay clear of interactive use; the ExcludePath
    # list above keeps it from grinding through Steam/docker/nix-store.
    scanner = {
      enable = true;
      interval = "Sat *-*-* 03:00:00";
      scanDirectories = [
        "/home"
        "/var/lib"
        "/tmp"
        "/var/tmp"
        "/etc"
        "/root"
      ];
    };
  };

  # clamonacc aborts at startup if a watched path is missing, so make sure
  # every Downloads directory exists before it runs. Note tmpfiles "d" also
  # re-asserts mode/ownership on existing dirs each boot; 0700 keeps other
  # users out of each other's downloads.
  systemd.tmpfiles.rules = lib.mapAttrsToList (
    name: u: "d ${u.home}/Downloads 0700 ${name} ${u.group} -"
  ) normalUsers;
}
