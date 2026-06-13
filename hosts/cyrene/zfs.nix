{
  config,
  pkgs,
  lib,
  ...
}:

let
  zfsCompatibleKernelPackages = lib.filterAttrs (
    name: kernelPackages:
    (builtins.match "linux_[0-9]+_[0-9]+" name) != null
    && (builtins.tryEval kernelPackages).success
    && (!kernelPackages.${config.boot.zfs.package.kernelModuleAttribute}.meta.broken)
  ) pkgs.linuxKernel.packages;
  latestKernelPackage = lib.last (
    lib.sort (a: b: (lib.versionOlder a.kernel.version b.kernel.version)) (
      builtins.attrValues zfsCompatibleKernelPackages
    )
  );

  # Roughly a week of sanoid-managed snapshots. nixos generation snapshots
  # (@nixos-*) are pruned separately in zfs-generation-snapshot below.
  snapshotRetention = {
    hourly = 72;
    daily = 7;
    monthly = 0;
    yearly = 0;
  };
  nixosSnapshotRetentionDays = 7;

  # Large, re-downloadable game data on dedicated datasets under
  # ~/.local/share/*. Each child gets its own sanoid entry (autosnap=false) so
  # sanoid's recursive home snapshots skip them.
  gameHomeMounts = {
    "/home/luluco/.local/share/Steam" = "rpool/nixos/home/luluco/steam";
    "/home/luluco/.local/share/anime-game-launcher" = "rpool/nixos/home/luluco/anime-game-launcher";
    "/home/luluco/.local/share/honkers-railway-launcher" =
      "rpool/nixos/home/luluco/honkers-railway-launcher";
    "/home/luluco/.local/share/sleepy-launcher" = "rpool/nixos/home/luluco/sleepy-launcher";
    "/home/luluco/.local/share/wavey-launcher" = "rpool/nixos/home/luluco/wavey-launcher";
  };

  # Nested ZFS datasets under /home/luluco must mount via `zfs mount` after the
  # home dataset is up. fileSystems + mountpoint=legacy races the parent mount
  # and fails when the mountpoint directory is non-empty.
  gameHomeMountScript = lib.concatMapStrings (
    mountPoint:
    let
      dataset = gameHomeMounts.${mountPoint};
    in
    ''
      dataset=${lib.escapeShellArg dataset}
      mount_point=${lib.escapeShellArg mountPoint}
      if mountpoint -q "$mount_point" 2>/dev/null; then
        :
      else
        if ! ${pkgs.zfs}/bin/zfs list -H -o name "$dataset" &>/dev/null; then
          echo "zfs-game-home: creating $dataset"
          ${pkgs.zfs}/bin/zfs create \
            -o mountpoint="$mount_point" \
            -o com.sun:auto-snapshot=false \
            -o canmount=noauto \
            "$dataset"
        else
          ${pkgs.zfs}/bin/zfs set \
            mountpoint="$mount_point" \
            com.sun:auto-snapshot=false \
            canmount=noauto \
            "$dataset"
        fi
        if ! ${pkgs.zfs}/bin/zfs mount "$dataset" 2>/dev/null; then
          echo "zfs-game-home: failed to mount $dataset at $mount_point" >&2
        fi
      fi
    ''
  ) (lib.attrNames gameHomeMounts);

  # After datasets mount: fix ownership and seed the Steam client bootstrap
  # (same tar Steam normally extracts on first launch). Launcher datasets stay
  # empty until first run — they have no Nix-store payload, only user data.
  gameHomeSeedScript =
    let
      mountPoints = lib.concatMapStringsSep " " lib.escapeShellArg (lib.attrNames gameHomeMounts);
      steamBootstrapTar = "${pkgs.steam-unwrapped}/lib/steam/bootstraplinux_ubuntu12_32.tar.xz";
    in
    ''
      game_user=luluco
      game_group=users
      home=/home/luluco

      for mount_point in ${mountPoints}; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
          chown "$game_user:$game_group" "$mount_point"
          chmod 700 "$mount_point"
        fi
      done

      ${lib.optionalString config.programs.steam.enable ''
        steam_dir="$home/.local/share/Steam"
        steam_config="$home/.steam"
        steam_bootstrap=${lib.escapeShellArg steamBootstrapTar}

        if mountpoint -q "$steam_dir" 2>/dev/null && [ ! -x "$steam_dir/steam.sh" ]; then
          echo "zfs-game-home: seeding Steam bootstrap into $steam_dir"
          tar xJf "$steam_bootstrap" -C "$steam_dir"
          cp -f "$steam_bootstrap" "$steam_dir/bootstrap.tar.xz"
          chown -R "$game_user:$game_group" "$steam_dir"
        fi

        if mountpoint -q "$steam_dir" 2>/dev/null && [ -x "$steam_dir/steam.sh" ]; then
          mkdir -p "$steam_config"
          ln -sfn "$steam_dir" "$steam_config/steam"
          chown -R "$game_user:$game_group" "$steam_config"
        fi
      ''}
    '';
in
{
  boot.supportedFilesystems = [
    "zfs"
    "ntfs"
  ];
  # ZFS must also be available in the initrd so the root pool is importable
  # early in boot and any ZFS fileSystems entries (e.g. /tmp) can be mounted
  # before userspace starts.
  boot.initrd.supportedFilesystems = [ "zfs" ];
  boot.kernelParams = [ "console=tty1" ];
  boot.zfs.forceImportRoot = true;
  boot.zfs.requestEncryptionCredentials = [ "rpool" ];
  boot.zfs.extraPools = [ "local-backup" ];
  # Unique per-host ZFS hostid. forceImportRoot above lets the root pool
  # reconcile this on the next boot's forced import without an export (which is
  # impossible for a live system root); see also local-backup, which needs a
  # one-time `zpool import -f local-backup` after the id changes.
  networking.hostId = "69e5e3ea";

  # Note this might jump back and forth as kernels are added or removed.
  boot.kernelPackages = latestKernelPackage;

  boot.loader = {
    efi = {
      efiSysMountPoint = "/boot";
      canTouchEfiVariables = true;
    };
    # lanzaboote replaces the systemd-boot install step with signed-UKI installs.
    systemd-boot = {
      enable = lib.mkForce false;
      configurationLimit = 20;
    };
  };

  boot.lanzaboote = {
    enable = true;
    # sbctl stores the Secure Boot PKI here.  Back this directory up offline.
    pkiBundle = "/etc/secureboot";
  };

  # Nix build sandboxes live in /tmp/nix-build-* on the host side. A dedicated
  # ZFS dataset keeps them off rpool/nixos/root (and therefore out of every
  # snapshot) while still letting large builds (Firefox, LLVM, etc.) grow into
  # whatever pool space is free — a fixed-size tmpfs would kill those builds.
  # sync=disabled is safe for /tmp: the kernel's page cache is the durability
  # guarantee here, not ZFS intent-log.
  #
  # The dataset must be created once (mountpoint=legacy is REQUIRED — without
  # it ZFS auto-mounts the dataset itself and races the fileSystems entry below,
  # causing a double-mount conflict on boot):
  #   sudo zfs create -o mountpoint=legacy \
  #                   -o com.sun:auto-snapshot=false \
  #                   -o sync=disabled \
  #                   rpool/nixos/tmp
  #   sudo chmod 1777 /tmp   # world-writable sticky bit
  #
  # Verify properties are set correctly:
  #   zfs get mountpoint,com.sun:auto-snapshot,sync rpool/nixos/tmp
  fileSystems."/tmp" = {
    device = "rpool/nixos/tmp";
    fsType = "zfs";
    options = [
      "zfsutil"
      "X-mount.mkdir"
      "noatime"
      "nodev"
      "nosuid"
      # mode=1777 is a tmpfs-only option; mount.zfs rejects it and fails the
      # mount. The sticky world-writable bit is set once on the dataset itself:
      #   sudo chmod 1777 /tmp
    ];
    # neededForBoot must stay false (the default). Setting it true moves the
    # mount into stage 1 and generates a sysroot-tmp.mount unit that tries to
    # mount rpool/nixos/tmp inside the initrd at /sysroot/tmp, before ZFS
    # userland is ready — causing the /sysroot/tmp boot error.
  };

  # Docker's zfs storage driver creates one dataset per image/container layer as
  # a child of whatever dataset holds /var/lib/docker. With the default data root
  # that dataset was rpool/nixos/var/lib, so every layer landed under the
  # snapshotted+replicated var tree and flooded sanoid, the generation-snapshot
  # activation script (zfs snapshot -r rpool/nixos@...), and syncoid with
  # hundreds of throwaway datasets and snapshots (they even got replicated to
  # local-backup).
  #
  # Give docker a dedicated dataset that lives OUTSIDE rpool/nixos so none of
  # those mechanisms can reach it:
  #   * the generation snapshot is `-r rpool/nixos`           -> rpool/docker is excluded
  #   * sanoid only configures the rpool/nixos/* trees        -> never sees it
  #   * syncoid's source is rpool/nixos                       -> never replicates it
  # rpool/docker is still encrypted (ZFS forces a child of an encrypted parent —
  # here the rpool encryption root — to inherit its key) and is tagged
  # com.sun:auto-snapshot=false for good measure.
  #
  # mountpoint=legacy on the dataset is REQUIRED for the same reason as /tmp
  # above: without it ZFS would auto-mount rpool/docker itself and race this
  # systemd mount (which, via RequiresMountsFor, correctly orders after the
  # /var/lib mount). The dataset must be created once:
  #   sudo zfs create -o mountpoint=legacy \
  #                   -o com.sun:auto-snapshot=false \
  #                   rpool/docker
  # See the one-time docker-storage migration steps committed alongside this
  # change for destroying the OLD per-layer datasets under rpool/nixos/var/lib
  # (and their replicas on local-backup) before switching over.
  fileSystems."/var/lib/docker" = {
    device = "rpool/docker";
    fsType = "zfs";
    options = [
      "zfsutil"
      "X-mount.mkdir"
      "noatime"
    ];
  };

  # Game datasets mount via zfs-game-home-mounts.service after /home/luluco.
  # Do not add fileSystems entries here — nested children race the home mount.

  boot.kernel.sysctl = {
    # ZFS manages its own page cache via the ARC; a high swappiness
    # causes the kernel to race against ZFS for the same pages and
    # makes OOM situations much worse. 10 is the standard ZFS recommendation.
    "vm.swappiness" = 10;
    # Tell the kernel to start reclaiming memory earlier (at 3% free)
    # rather than waiting until it is nearly exhausted.
    "vm.min_free_kbytes" = 2097152; # 2 GiB
  };

  boot.zswap = {
    enable = true;
    compressor = "zstd";
    zpool = "zsmalloc";
    maxPoolPercent = 25;
  };

  # The ZVOL swap device is disabled because it was causing issues with the
  # kernel. The ARC cache was not able to keep up with the swap requests, and
  # the kernel was swapping out pages that were still in use. Swap now lives on
  # the Samsung 870 EVO (see default.nix). Reclaim the unused zvol once:
  #   swapon --show | grep -q rpool/swap && echo "still in use" && exit 1
  #   sudo zfs destroy rpool/swap
  #swapDevices = [
  #  { device = "/dev/zvol/rpool/swap"; }
  #];

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

  # Set dataset properties on switch; mounts + seeding also run at boot.
  system.activationScripts.zfs-game-home-datasets = {
    deps = [ "zfs-home-datasets" ];
    text = ''
      if [ -d /home/luluco ]; then
        set +e
        ${gameHomeMountScript}
        ${gameHomeSeedScript}
      fi
    '';
  };

  systemd.services.zfs-game-home-mounts = {
    description = "Mount game launcher ZFS datasets under ~/.local/share";
    after = [ "zfs-import.target" ];
    requires = [ "zfs-import.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.zfs
      pkgs.util-linux
      pkgs.xz
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RequiresMountsFor = "/home/luluco";
    };
    script = ''
      set -e
      home=/home/luluco
      share="$home/.local/share"
      stale_mounts=(
        "$home/steam"
        "$home/anime-game-launcher"
        "$home/honkers-railway-launcher"
        "$home/sleepy-launcher"
        "$home/wavey-launcher"
      )

      mkdir -p "$share"
      chown luluco:users "$home/.local" "$share" || true
      chmod 755 "$home/.local" "$share" || true

      for stale in "''${stale_mounts[@]}"; do
        if mountpoint -q "$stale" 2>/dev/null; then
          umount "$stale" 2>/dev/null || true
        fi
        rmdir "$stale" 2>/dev/null || true
      done

      set +e
      ${gameHomeMountScript}
      ${gameHomeSeedScript}
    '';
  };

  services.sanoid = {
    enable = true;
    interval = "hourly";

    # Home: longer retention; recursive covers all per-user sub-datasets
    # automatically — no per-user entry needed when new users are added.
    datasets."rpool/nixos/home" = {
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

    # Game data: large, constantly changing, fully re-downloadable.
    # Each lives on its own dataset with a sanoid entry (autosnap=false) so
    # sanoid's recursive home snapshots skip it; see gameHomeMounts + fileSystems.
    datasets."rpool/nixos/home/luluco/steam" = {
      autosnap = false;
      autoprune = false;
    };
    datasets."rpool/nixos/home/luluco/anime-game-launcher" = {
      autosnap = false;
      autoprune = false;
    };
    datasets."rpool/nixos/home/luluco/honkers-railway-launcher" = {
      autosnap = false;
      autoprune = false;
    };
    datasets."rpool/nixos/home/luluco/sleepy-launcher" = {
      autosnap = false;
      autoprune = false;
    };
    datasets."rpool/nixos/home/luluco/wavey-launcher" = {
      autosnap = false;
      autoprune = false;
    };

    datasets."rpool/nixos/tmp" = {
      autosnap = false;
      autoprune = false;
    };

    datasets."rpool/nixos/root" = {
      autoprune = true;
      autosnap = true;
      inherit (snapshotRetention)
        hourly
        daily
        monthly
        yearly
        ;
    };

    datasets."rpool/nixos/var" = {
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

  services.syncoid = {
    enable = true;
    sshKey = "/etc/syncoid/.ssh/id_rsa";
    localSourceAllow = [
      "change-key"
      "compression"
      "create"
      "mount"
      "mountpoint"
      "receive"
      "rollback"
      "bookmark"
      "hold"
      "release"
      "send"
      "snapshot"
      "destroy"
    ];
    localTargetAllow = [
      "change-key"
      "compression"
      "create"
      "mount"
      "mountpoint"
      "receive"
      "rollback"
      "bookmark"
      "hold"
      "release"
      "send"
      "snapshot"
      "destroy"
    ];
    commonArgs = [
      ''--sshoption="UserKnownHostsFile=/etc/syncoid/.ssh/known_hosts"''
      "--compress=zstd-fast"
      "--recursive"
      # NOTE: do NOT put --sendoptions here. The NixOS syncoid module always
      # appends its own `--sendoptions <value>` at the end of the command, so
      # any --sendoptions in commonArgs would be silently overridden (Getopt
      # last-value-wins). Set sendOptions per-command instead.
    ];
    # Remote replication to rsync.net is pending SSH setup (the key at
    # /etc/syncoid/.ssh/id_rsa does not exist yet and the host is unreachable).
    # Leave it disabled until the key/known_hosts are provisioned, otherwise its
    # ExecStopPost `zfs unallow` races the local job and revokes the shared
    # rpool/nixos send/snapshot permissions mid-run ("permission denied").
    #
    # If local-backup replication is broken (pool full, stale syncoid holds, or
    # a diverged incremental chain), recover with:
    #   sudo zfs holds -r rpool/nixos
    #   sudo zfs release syncoid <snapshot>   # repeat for each stale hold
    #   sudo sanoid --prune-snapshots --verbose
    #   sudo zfs destroy -r local-backup/cyrene/rpool/nixos
    #   sudo systemctl start syncoid-local-target-init.service
    #   sudo systemctl start syncoid-rpool-nixos-local.service
    # commands."rpool/nixos" = {
    #   source = "rpool/nixos";
    #   target = "syncoid@zh2883b.rsync.net:data1/Cyrene/rpool/nixos";
    #   sendOptions = "w";
    #   extraArgs = [ "--use-hold" ];
    # };
    commands."rpool/nixos-local" = {
      source = "rpool/nixos";
      target = "local-backup/cyrene/rpool/nixos";
      # Raw send preserves the on-disk encrypted blocks; the local-backup pool
      # never needs to hold or know the encryption key.
      sendOptions = "w";
      # Place a ZFS hold on the last-sent source snapshot so sanoid's autoprune
      # cannot delete it between syncoid runs. Without this, sanoid could prune
      # the anchor snapshot and force a full resend on the next run. The hold is
      # released automatically after the next successful incremental send.
      extraArgs = [
        "--use-hold"
        # rpool/nixos/tmp is a no-snapshot build-sandbox dataset; there is
        # nothing worth backing up there and it could be enormous mid-build.
        "--exclude-datasets=rpool/nixos/tmp"
        # Game launcher and Steam datasets are large, constantly changing, and
        # fully re-downloadable — not worth the backup storage cost.
        "--exclude-datasets=rpool/nixos/home/luluco/anime-game-launcher"
        "--exclude-datasets=rpool/nixos/home/luluco/honkers-railway-launcher"
        "--exclude-datasets=rpool/nixos/home/luluco/sleepy-launcher"
        "--exclude-datasets=rpool/nixos/home/luluco/steam"
        "--exclude-datasets=rpool/nixos/home/luluco/wavey-launcher"
        # Docker uses the ZFS storage driver (virtualisation.docker.storageDriver
        # = "zfs") rooted at the rpool/nixos/var/lib dataset, so every image
        # layer and container is an ephemeral child dataset there: 64-hex layer
        # IDs, "<id>-init" container layers, and 25-char container IDs. Raw
        # replication with --use-hold places a ZFS hold on each one's snapshot,
        # which then blocks `docker rm`/`docker rmi` ("cannot destroy snapshot
        # ... it's being held") until the next syncoid run. They are fully
        # rebuildable, so skip them entirely. The regex matches any child of
        # var/lib whose name is a 25+-char run of [a-z0-9] (all three docker
        # dataset name forms) while still backing up the var/lib dataset itself
        # and any normally-named child datasets.
        "--exclude-datasets=rpool/nixos/var/lib/[a-z0-9]{25,}"
      ];
    };
  };

  # The syncoid NixOS module only delegates ZFS permissions on the *target* if
  # that dataset (or its parent) already exists; otherwise the zfs-allow
  # pre-hook is a silently-ignored no-op and the actual `zfs receive` fails with
  # "permission denied". The local-backup pool is only imported by this config
  # (boot.zfs.extraPools), never provisioned, so create the container datasets
  # that hold the backup before syncoid runs. canmount=off/mountpoint=none keeps
  # these intermediate containers from mounting anywhere; the received
  # rpool/nixos tree carries its own (raw, encrypted) properties.
  systemd.services.syncoid-local-target-init = {
    description = "Create local-backup container datasets for syncoid";
    after = [ "zfs-import.target" ];
    requiredBy = [ "syncoid-rpool-nixos-local.service" ];
    before = [ "syncoid-rpool-nixos-local.service" ];
    path = [ pkgs.zfs ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for ds in local-backup/cyrene local-backup/cyrene/rpool; do
        if ! zfs list -H "$ds" >/dev/null 2>&1; then
          zfs create -o canmount=off -o mountpoint=none "$ds"
        fi
      done
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

  zfsHome = {
    enable = true;
    poolName = "rpool";
    defaultQuota = "500G";
    users = [
      "luluco"
      "phainon"
    ];
  };

  users.users.root.initialHashedPassword = "$6$31uKiv3HbrCU2pbC$D9qnquW32p.8cZH5yz.7j5ExFywS.6j2gii.bqZIRDj551HI2WO5yUiMsUUg0nP.KAXWtSEOj0.VWsXt0uAqt1";
}
