# CHITUBOX — slicer for SLA/DLP/LCD resin printers. CHITU merged the old
# Basic/Pro products into a single app in late 2025 and dropped the Linux
# builds with it: the last native Linux release is Basic v2.3.1 (Jan 2025),
# and the current unified releases (upgrade number v3.3.0 = app v1.2.0) ship
# Windows and macOS only (stableLinuxUrl is null in their download API).
# Following the xtool-studio module next door, the unmodified Windows build
# runs under Wine.
#
# What the payload is (looked at 2026-07): a Qt 6 QML application
# (librabbit_* slicer/render DLLs, CadEx importers for STEP/OBJ/3MF/etc.)
# plus QtWebEngine — an embedded Chromium that renders the account
# login / user-center views. Verified under wine 11 (64-bit): installs
# headless in ~15 s, launches to the login screen and renders it correctly.
#
# Why the launcher installs on first run instead of unpacking into the store:
#   The installer is Qt Installer Framework 4.6, not NSIS — the application
#   archives are appended to the PE in QtIFW's own resource-collection format
#   that 7z cannot parse (it only finds a stray font archive). Extracting at
#   build time would need QtIFW's `devtool dump`; nixpkgs only carries QtIFW
#   2.0.3 (2016), which predates the 4.x format. QtIFW installers are fully
#   scriptable headless, though, so the launcher performs a one-shot
#     wine installer.exe --root C:\chitubox \
#       --accept-licenses --accept-messages --confirm-command in
#   into the wineprefix, stamped by the installer's store path; on a version
#   bump it purges the old install through the bundled maintenance tool
#   (Uninstall.exe) and reinstalls. The vendor installer, maintenance tool and
#   app all run inside the sandbox — only trusted nixpkgs wine (wineboot,
#   regedit) runs outside it.
#
#   The prefix's Desktop shell folder is a wineboot-made symlink to the real
#   ~/Desktop; the installer unconditionally drops a CHITUBOX.lnk there, which
#   would clutter the real desktop (and fail under bubblewrap, where ~/Desktop
#   is read-only, rolling back the whole install). The launcher therefore
#   replaces that symlink with a plain directory inside the prefix before
#   installing.
#
# GPU workaround: QtWebEngine's Chromium GPU process cannot create D3D11
# shared images under Wine (ANGLE -> wined3d, "Unable to create shared handle
# for DXGIResource"), and retries in a tight loop — ~80k error lines in a
# minute of uptime. QTWEBENGINE_CHROMIUM_FLAGS=--disable-gpu-compositing
# makes the webviews composite on the CPU, which removes the spam entirely
# with no visible regression (A/B-tested on the login screen). The Qt Quick
# scene graph (the actual 3D viewport) is unaffected — it renders through
# Qt's own RHI, not through the webengine. Override the flag at runtime via
# CHITUBOX_WEBENGINE_FLAGS (set to a single space to pass nothing).
#
# The app requires a CHITU account (free tier) — the login screen is the
# first thing it shows — so cloud reachability (DNS + TLS) must work inside
# the sandbox; see the resolv/nscd binds in bwrapExec.
#
# State follows the XDG base-dir spec:
#   $XDG_DATA_HOME/chitubox/wine    the 64-bit wineprefix (data); the app
#                                   lives in its drive_c/chitubox, settings
#                                   and profiles under drive_c/users/<user>
#   $XDG_STATE_HOME/chitubox/       run + install logs and apply-once stamps
# defaulting to ~/.local/share and ~/.local/state. CHITUBOX_HOME overrides
# the data base.
#
# Sandboxing (programs.chitubox.sandbox, default "bubblewrap"): same design
# and rationale as programs.xtool-studio.sandbox — see the Sandboxing note in
# ../xtool-studio/default.nix. The one deviation: ~/Downloads is bound
# READ-WRITE here, because a slicer's end product is an exported .ctb/.goo
# job file the user must be able to reach from outside the sandbox (the
# import folders stay read-only).
#
# Updating: bump version + upgradeVersion + hash. Current URLs come from
#   https://sac.chitubox.com/getSoftwareBySoftwareId.do2?softwareId=17839
# (the same endpoint the download page uses; 17839 is the Basic/free
# channel — 17842, the old Pro channel, serves the identical unified binary).

{ config, pkgs, lib, ... }:

let
  cfg = config.programs.chitubox;

  # The app's own version; upgradeVersion is CHITU's marketing/"upgrade
  # version number" that only appears in the download path.
  version = "1.2.0";
  upgradeVersion = "3.3.0";

  installer = pkgs.fetchurl {
    url = "https://download.chitubox.com/17839/v${upgradeVersion}/CHITUBOX_WIN64_Installer_v${version}.exe";
    hash = "sha256-PR6KEVnrZwV3lKfQqb2k6kmWseV0croi111v6/3QN7I=";
  };

  # 64-bit-only Wine is sufficient: the payload is x64 and pulls no 32-bit
  # dependencies. wineboot in the launcher initializes the prefix on first run.
  wine = pkgs.wine64;

  # Fonts for the wineprefix. QtWebEngine is Chromium and renders text via
  # DirectWrite, which only enumerates C:\windows\Fonts (the same failure mode
  # as xtool-studio's blank labels); the Qt side asks for the Windows UI
  # families by name. Same flat directory of font files, linked into the
  # prefix by the launcher: corefonts for real Arial/Verdana/Times,
  # Liberation + DejaVu for free wide-coverage sans/serif/mono and symbols,
  # Noto Sans CJK SC for the Chinese strings (the app bundles only simhei).
  wineFonts =
    pkgs.runCommand "chitubox-wine-fonts"
      {
        fontPackages = [
          pkgs.corefonts
          pkgs.liberation_ttf
          pkgs.dejavu_fonts
          pkgs.noto-fonts-cjk-sans
        ];
      }
      ''
        mkdir $out
        find -L $fontPackages \
          \( -name '*.ttf' -o -name '*.ttc' -o -name '*.otf' \) \
          -exec ln -st $out {} +
      '';

  # One-shot prefix registry setup, applied by the launcher (REGEDIT4 / ANSI):
  # prefer Wine's native Wayland driver with X11/XWayland fallback, and map
  # the Windows font family names onto fonts present in wineFonts. Same
  # rationale as the xtool-studio wineRegistry.
  #
  # Drives\c: = "hd" pins GetDriveType(C:) to DRIVE_FIXED. Inside bubblewrap
  # the minimal --dev /dev has no block-device nodes, so Wine's mountmgr
  # cannot classify the device backing the prefix and reports the drive type
  # as unknown — which CHITU's installer control script rejects ("The path
  # you have entered is not valid, please make sure to specify a valid
  # drive"), aborting the headless install. Verified: with this override the
  # install succeeds under the hardened /dev; without it only a full
  # --dev-bind /dev does.
  wineRegistry = pkgs.writeText "chitubox-wine.reg" ''
    REGEDIT4

    [HKEY_CURRENT_USER\Software\Wine\Drivers]
    "Graphics"="wayland,x11"

    [HKEY_LOCAL_MACHINE\Software\Wine\Drives]
    "c:"="hd"

    [HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]
    "Segoe UI"="Arial"
    "Segoe UI Semibold"="Arial"
    "Segoe UI Symbol"="DejaVu Sans"
    "Microsoft YaHei"="Noto Sans CJK SC"
    "Microsoft YaHei UI"="Noto Sans CJK SC"
    "SimSun"="Noto Sans CJK SC"
    "NSimSun"="Noto Sans CJK SC"
    "SimHei"="Noto Sans CJK SC"
    "PingFang SC"="Noto Sans CJK SC"
  '';

  # Shared launcher preamble: prefix env, first-run wineboot, font + registry
  # setup, HiDPI, webengine GPU flag. Runs before the sandbox — only trusted
  # nixpkgs wine, writing only into the state/data dirs. Vendor code (the
  # installer and the app) runs after, confined.
  launcherPreamble = ''
    dataHome="''${CHITUBOX_HOME:-''${XDG_DATA_HOME:-$HOME/.local/share}/chitubox}"
    stateHome="''${XDG_STATE_HOME:-$HOME/.local/state}/chitubox"
    export WINEPREFIX="$dataHome/wine"
    export WINEDEBUG="''${WINEDEBUG:--all}"
    # DLL overrides, ';'-joined:
    #   winemenubuilder.exe=d  don't scatter Start-menu .desktop files
    #   mscoree= / mshtml=     disable the Mono/.NET and Gecko auto-installers
    #     (modal download dialogs on first wineboot; CHITUBOX is Qt + its own
    #     Chromium, neither runtime is used).
    export WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree=;mshtml=;''${WINEDLLOVERRIDES:-}"

    mkdir -p "$dataHome" "$stateHome"
    if [ ! -f "$WINEPREFIX/system.reg" ]; then
      wineboot -u >/dev/null 2>&1 || true
    fi

    # Keep installer/app writes off the real desktop (see header): the prefix
    # Desktop shell folder is a symlink to ~/Desktop; make it a plain dir.
    desktopDir="$WINEPREFIX/drive_c/users/$USER/Desktop"
    if [ -L "$desktopDir" ]; then
      rm "$desktopDir" && mkdir "$desktopDir"
    fi

    # Fonts (see wineFonts above): refresh the nix-managed links in the
    # prefix's Fonts dir on every launch so font upgrades propagate, sweeping
    # stale store links from previous generations first.
    fontdir="$WINEPREFIX/drive_c/windows/Fonts"
    mkdir -p "$fontdir"
    find "$fontdir" -maxdepth 1 -type l -lname '/nix/store/*' -delete
    ln -sft "$fontdir" ${wineFonts}/*

    # Prefix registry (graphics driver + font substitutes; see wineRegistry
    # above): re-applied only when its store path changes.
    if [ "$(cat "$stateHome/.wine-registry" 2>/dev/null || true)" != "${wineRegistry}" ]; then
      if wine regedit /S "${wineRegistry}" >/dev/null 2>&1; then
        printf '%s' '${wineRegistry}' >"$stateHome/.wine-registry"
      fi
    fi

    # HiDPI: map a scale factor to Wine's LogPixels (96 = 100%, 144 = 150%,
    # 192 = 200%); Qt reads the Windows system DPI and scales the whole UI.
    # Precedence: CHITUBOX_SCALE env override, then the programs.chitubox.scale
    # option, then the desktop's GDK_SCALE hint; unset leaves Wine at its
    # default. On Wayland winewayland.drv additionally honours the
    # compositor's per-output scale.
    scale="''${CHITUBOX_SCALE:-${lib.optionalString (cfg.scale != null) cfg.scale}}"
    scale="''${scale:-''${GDK_SCALE:-}}"
    if [ -n "$scale" ]; then
      logpixels="$(awk -v s="$scale" 'BEGIN { printf "%d", (96 * s) + 0.5 }')"
      if [ "$(cat "$stateHome/.logpixels" 2>/dev/null || true)" != "$logpixels" ]; then
        if wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD \
          /d "$logpixels" /f >/dev/null 2>&1; then
          printf '%s' "$logpixels" >"$stateHome/.logpixels"
        fi
      fi
    fi

    # GPU workaround (see header): stop QtWebEngine's Chromium from fighting
    # wined3d over D3D11 shared images. Env is inherited into the Windows
    # process, where QtWebEngine picks this variable up.
    export QTWEBENGINE_CHROMIUM_FLAGS="''${CHITUBOX_WEBENGINE_FLAGS:---disable-gpu-compositing}"

    # Flush the prefix registry to disk before any sandboxed wine starts.
    # The preamble's wineserver lingers ~3 s after its last client (wineboot/
    # regedit) exits and only writes system.reg/user.reg on exit; the
    # sandboxed wine below lives in its own pid namespace with /tmp hidden,
    # so it cannot join that wineserver and instead reads the registry from
    # disk — racing the flush. Lost race = the Drives override above is
    # missing and the first-run install fails its drive-type check.
    # wineserver -w waits for the running server (if any) to exit.
    wineserver -w
  '';

  # Bubblewrap sandbox: identical policy to xtool-studio's bwrapExec (host
  # net namespace shared for cloud login + LAN send-to-printer, everything
  # else unshared, caps dropped), except Downloads is read-write — see the
  # Sandboxing note in the header. `wrap` is prefixed to every vendor-code
  # invocation (installer, maintenance tool, app).
  bwrapSetup = ''
    bwrap_args=(
      --unshare-user
      --unshare-ipc
      --unshare-pid
      --unshare-uts
      --unshare-cgroup
      --new-session
      --die-with-parent
      --ro-bind /nix/store /nix/store
      --ro-bind /etc /etc
      # DNS inside the sandbox: /etc/resolv.conf is a symlink chain ending in
      # /run/systemd/resolve/stub-resolv.conf (systemd-resolved), and glibc
      # NSS prefers the nscd socket (NixOS runs nscd/nsncd by default).
      # Binding /etc alone leaves both dangling and the account login
      # times out on dead DNS.
      --ro-bind-try /run/systemd/resolve /run/systemd/resolve
      --ro-bind-try /run/nscd /run/nscd
      --proc /proc
      --dev /dev
      --ro-bind-try /sys /sys
      --ro-bind-try /run/opengl-driver /run/opengl-driver
      --ro-bind-try /run/opengl-driver-32 /run/opengl-driver-32
      --dev-bind-try /dev/dri /dev/dri
      --dev-bind-try /dev/snd /dev/snd
      --dev-bind-try /dev/nvidia0 /dev/nvidia0
      --dev-bind-try /dev/nvidiactl /dev/nvidiactl
      --dev-bind-try /dev/nvidia-modeset /dev/nvidia-modeset
      --dev-bind-try /dev/nvidia-uvm /dev/nvidia-uvm
      --dev-bind-try /dev/nvidia-uvm-tools /dev/nvidia-uvm-tools
      --tmpfs /tmp
      --ro-bind-try /tmp/.X11-unix /tmp/.X11-unix
      --tmpfs "$HOME"
      --bind "$dataHome" "$dataHome"
      --bind "$stateHome" "$stateHome"
      # Writable: where exported .ctb/.goo job files land (see header).
      --bind-try "$HOME/Downloads" "$HOME/Downloads"
    )

    # Read-only access to the usual model/import folders (skipped when
    # absent), plus fonts and the fontconfig cache.
    for d in Documents Pictures Desktop Projects .fonts ".local/share/fonts" ".cache/fontconfig"; do
      bwrap_args+=(--ro-bind-try "$HOME/$d" "$HOME/$d")
    done

    # Session runtime dir (Wayland socket — the preferred transport, see
    # wineRegistry — plus PulseAudio / PipeWire) and the X11 auth cookie for
    # the XWayland/X11 fallback; read-only, only if present. Env is inherited
    # so WAYLAND_DISPLAY / DISPLAY / XAUTHORITY / XDG_RUNTIME_DIR reach the
    # child unchanged.
    if [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
      bwrap_args+=(--ro-bind-try "$XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR")
    fi
    if [ -n "''${XAUTHORITY:-}" ]; then
      bwrap_args+=(--ro-bind-try "$XAUTHORITY" "$XAUTHORITY")
    fi

    wrap=(bwrap "''${bwrap_args[@]}")
  '';

  # No-op / firejail path: run vendor code directly. When sandbox = "firejail"
  # the programs.firejail wrapper (below) confines this whole launcher
  # externally.
  plainSetup = ''
    wrap=()
  '';

  # First-run / version-change install (see header). The stamp is the
  # installer's store path, so a version bump triggers purge + reinstall; the
  # purge goes through the bundled QtIFW maintenance tool so the prefix
  # registry stays consistent, with rm -rf as the fallback for half-installed
  # trees. network.xml (the maintenance tool's online-repo list) is removed:
  # the install dir is nix-managed by the stamp, so a self-update could only
  # drift the app away from what the module pins.
  #
  # The stdio redirects are for troubleshooting (QtIFW logs every operation);
  # unlike xtool-studio's Electron EBADF crash they are not load-bearing.
  installExec = ''
    if [ "$(cat "$stateHome/.installed" 2>/dev/null || true)" != "${installer}" ]; then
      {
        if [ -f "$WINEPREFIX/drive_c/chitubox/Uninstall.exe" ]; then
          "''${wrap[@]}" wine 'C:\chitubox\Uninstall.exe' \
            --confirm-command purge || true
        fi
        rm -rf "$WINEPREFIX/drive_c/chitubox"
        "''${wrap[@]}" wine "${installer}" --root 'C:\chitubox' \
          --accept-licenses --accept-messages --confirm-command in
        rm -f "$WINEPREFIX/drive_c/chitubox/network.xml"
      } >"$stateHome/chitubox-install.log" 2>&1 </dev/null
      printf '%s' '${installer}' >"$stateHome/.installed"
    fi
  '';

  appExec = ''
    exec "''${wrap[@]}" wine 'C:\chitubox\CHITUBOX.exe' "$@" \
      >"$stateHome/chitubox.log" 2>&1 </dev/null
  '';

  # writeShellApplication runs under `set -euo pipefail`; bash >= 4.4 expands
  # the empty wrap=() cleanly under -u.
  useBwrap = cfg.sandbox == "bubblewrap";
  launcher = pkgs.writeShellApplication {
    name = "chitubox";
    runtimeInputs = [
      wine # wine + wineboot on PATH
    ] ++ lib.optional useBwrap pkgs.bubblewrap;
    text =
      launcherPreamble + (if useBwrap then bwrapSetup else plainSetup) + installExec + appExec;
  };

  chitubox = pkgs.stdenvNoCC.mkDerivation {
    pname = "chitubox";
    inherit version;

    dontUnpack = true;

    nativeBuildInputs = with pkgs; [
      icoutils # wrestool: installer PE resources -> .ico
      imagemagick # .ico -> hicolor PNGs
      copyDesktopItems
    ];

    desktopItems = [
      (pkgs.makeDesktopItem {
        name = "chitubox";
        exec = "chitubox %U";
        icon = "chitubox";
        desktopName = "CHITUBOX";
        comment = "Slicer for SLA/DLP/LCD resin 3D printers (Wine)";
        categories = [
          "Graphics"
          "Engineering"
        ];
        mimeTypes = [ "application/x-chitubox" ];
      })
    ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin
      ln -s ${launcher}/bin/chitubox $out/bin/chitubox

      # The application tree only materializes at first launch (see header),
      # so the icon comes from the installer's own PE resources: IDI_ICON1
      # language 0 is the product logo (up to 256x256; the language-1033
      # sibling is the generic QtIFW icon). Frame order inside the .ico is
      # not guaranteed, so find the largest frame and scale that.
      wrestool -x --type=14 --name=IDI_ICON1 --language=0 \
        -o chitubox.ico ${installer}
      best="$(magick identify -format '%w %s\n' chitubox.ico | sort -n | tail -1 | cut -d' ' -f2)"
      for size in 32 64 128 256; do
        mkdir -p $out/share/icons/hicolor/"$size"x"$size"/apps
        magick "chitubox.ico[$best]" -resize "$size"x"$size" \
          $out/share/icons/hicolor/"$size"x"$size"/apps/chitubox.png
      done

      runHook postInstall
    '';

    meta = {
      description = "CHITUBOX resin printer slicer (Windows build run via Wine)";
      homepage = "https://www.chitubox.com/";
      license = lib.licenses.unfree;
      platforms = [ "x86_64-linux" ];
      mainProgram = "chitubox";
    };
  };
in
{
  options.programs.chitubox.sandbox = lib.mkOption {
    type = lib.types.enum [
      "bubblewrap"
      "firejail"
      "none"
    ];
    default = "bubblewrap";
    description = ''
      How to confine the (proprietary, closed-source) CHITUBOX binary; same
      backends and rationale as {option}`programs.xtool-studio.sandbox`.

      - "bubblewrap": wrap wine in bwrap, baked into the launcher. Default;
        unprivileged (user namespaces), no setuid helper.
      - "firejail": enable {option}`programs.firejail` and wrap the launcher
        with the bundled firejail.profile. Choose this if the host already
        standardises on firejail.
      - "none": run unconfined.
    '';
  };

  options.programs.chitubox.scale = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "1.5";
    description = ''
      HiDPI scale factor for the CHITUBOX UI, as a multiplier of 100% (e.g.
      "1.5" = 150%, "2" = 200%). Translated to Wine's LogPixels, which Qt
      reads as the system DPI. `null` leaves Wine at its default — on Wayland
      winewayland.drv follows the compositor's output scale, so an explicit
      value is mainly needed on X11 or to override. The `CHITUBOX_SCALE`
      environment variable overrides this at runtime.
    '';
  };

  config = {
    # The desktop file's bare `Exec=chitubox` resolves to `launcher` on PATH.
    # For "bubblewrap"/"none" that launcher is the whole story; for "firejail"
    # the firejail module builds a same-named wrapper with meta.priority = -1
    # that shadows it and applies the profile.
    environment.systemPackages = [ chitubox ];

    programs.firejail = lib.mkIf (cfg.sandbox == "firejail") {
      enable = true;
      wrappedBinaries.chitubox = {
        executable = "${chitubox}/bin/chitubox";
        profile = ./firejail.profile;
        extraArgs = [ "--quiet" ];
      };
    };

    # LAN send-to-printer discovery, best-effort: CBD-firmware printers (and
    # the newer SDCP protocol used by ELEGOO et al.) listen on UDP 3000 and
    # answer discovery broadcasts with a unicast reply. Broadcast UDP doesn't
    # create usable conntrack entries (the reply's source doesn't match the
    # broadcast destination tuple), so the response needs an open port.
    # NB: unlike the xtool-studio rules this is NOT verified against hardware
    # — no resin printer was on the LAN at porting time.
    networking.firewall.allowedUDPPorts = [ 3000 ];
  };
}
