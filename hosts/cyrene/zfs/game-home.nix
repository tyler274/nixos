{
  config,
  pkgs,
  lib,
  ...
}:

let
  cyreneZfs = import ./lib.nix { inherit lib; };
  inherit (cyreneZfs) gameHomeMounts;

  # Nested ZFS datasets under /home/luluco must mount via `zfs mount` after the
  # home dataset is up. fileSystems + mountpoint=legacy races the parent mount
  # and fails when the mountpoint directory is non-empty.
  # Use `zfs get mounted`, not mountpoint(1): nested datasets and stale directory
  # stubs on the home dataset disagree with mountpoint, and `zfs set mountpoint`
  # on an already-mounted filesystem tries to unmount first (breaks with Steam).
  gameHomeMountedHelper = ''
    game_dataset_mounted() {
      ${pkgs.zfs}/bin/zfs get -H -o value mounted "$1" 2>/dev/null | grep -qx yes
    }
  '';

  gameHomeMountScript = lib.concatMapStrings (
    mountPoint:
    let
      dataset = gameHomeMounts.${mountPoint};
    in
    ''
      dataset=${lib.escapeShellArg dataset}
      mount_point=${lib.escapeShellArg mountPoint}
      if game_dataset_mounted "$dataset"; then
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
      mountPoints = lib.attrNames gameHomeMounts;
      steamBootstrapTar = "${pkgs.steam-unwrapped}/lib/steam/bootstraplinux_ubuntu12_32.tar.xz";
      tar = lib.getExe pkgs.gnutar;
      cp = lib.getExe' pkgs.coreutils "cp";
      chown = lib.getExe' pkgs.coreutils "chown";
      chmod = lib.getExe' pkgs.coreutils "chmod";
      mkdir = lib.getExe' pkgs.coreutils "mkdir";
      ln = lib.getExe' pkgs.coreutils "ln";
      seedForMount = mountPoint:
        let
          dataset = gameHomeMounts.${mountPoint};
        in
        ''
          mount_point=${lib.escapeShellArg mountPoint}
          dataset=${lib.escapeShellArg dataset}
          if game_dataset_mounted "$dataset"; then
            ${chown} "$game_user:$game_group" "$mount_point"
            ${chmod} 700 "$mount_point"
          fi
        '';
    in
    ''
      export PATH=${lib.makeBinPath [
        pkgs.gnutar
        pkgs.xz
        pkgs.coreutils
      ]}:''${PATH:-}
      game_user=luluco
      game_group=users
      home=/home/luluco

      ${lib.concatMapStrings seedForMount mountPoints}

      ${lib.optionalString config.programs.steam.enable ''
        steam_dir="$home/.local/share/Steam"
        steam_config="$home/.steam"
        steam_dataset=${lib.escapeShellArg gameHomeMounts."/home/luluco/.local/share/Steam"}
        steam_bootstrap=${lib.escapeShellArg steamBootstrapTar}

        if game_dataset_mounted "$steam_dataset" && [ ! -x "$steam_dir/steam.sh" ]; then
          echo "zfs-game-home: seeding Steam bootstrap into $steam_dir"
          ${tar} xJf "$steam_bootstrap" -C "$steam_dir"
          ${cp} -f "$steam_bootstrap" "$steam_dir/bootstrap.tar.xz"
          ${chown} -R "$game_user:$game_group" "$steam_dir"
        fi

        if game_dataset_mounted "$steam_dataset" && [ -x "$steam_dir/steam.sh" ]; then
          ${mkdir} -p "$steam_config"
          ${ln} -sfn "$steam_dir" "$steam_config/steam"
          ${chown} -R "$game_user:$game_group" "$steam_config"
        fi
      ''}
    '';
in
{
  # Set dataset properties on switch; mounts + seeding also run at boot.
  system.activationScripts.zfs-game-home-datasets = {
    deps = [ "zfs-home-datasets" ];
    text = ''
      if [ -d /home/luluco ]; then
        set +e
        ${gameHomeMountedHelper}
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
      pkgs.gnutar
      pkgs.xz
      pkgs.coreutils
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
      ${gameHomeMountedHelper}
      ${gameHomeMountScript}
      ${gameHomeSeedScript}
    '';
  };
}
