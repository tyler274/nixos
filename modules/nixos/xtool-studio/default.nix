# xTool Studio — vendor software for xTool laser cutters (the M2 in
# particular; M2 support requires Studio >= 1.7.30, and the older XCS never
# supported it). xTool ships Windows and macOS builds only; there is no
# official Linux support.
#
# Why Wine instead of a native Electron repack:
#   Studio is an Electron 36 app, but its device stack is proprietary native
#   code with no Linux builds published anywhere (their npm registry is
#   private, checked 2026-07):
#     - @xtool/atomm_cpp_module     (job/plot engine; win32+darwin .node only)
#     - @atomm-studio/system-rs     (Rust napi module; win32+darwin only)
#     - resources/tools/algo-server (path planning / time estimation / image
#                                    processing server; algo-server-win32-x64.exe
#                                    plus a dozen Windows-only DLL plugins)
#   Re-hosting the asar on a Linux Electron (the AUR xtool-creative-space
#   approach) therefore yields an editor that starts but cannot talk to the
#   machine or compile jobs — the AUR maintainer reached the same dead end for
#   XCS 2.7. Running the unmodified Windows build under Wine keeps all the
#   native pieces working. Verified 2026-07 under wine 11 (64-bit):
#     - the Electron UI reaches region-select / ToS / home / editor canvas;
#     - atomm_cpp_module ships an electron/36.2 prebuild that matches the
#       bundled Electron (resources/version = 36.2.0), so it loads in-process;
#     - algo-server-win32-x64.exe (the Rust job-compute backend, spawned
#       lazily when a job is framed/processed — not at startup) loads all its
#       plugin DLLs under Wine with zero loader errors and reaches app logic
#       (it exits demanding the ALGO_SERVER_TOKEN that Studio injects).
#
# How the M2 actually connects (from ext.json inside the app):
#   The M2 (deviceCode JS002) is a protocol-V2, channelType "socket" device
#   for both USB and Wi-Fi — there is no serial-port mode. "USB" means the
#   machine enumerates as a USB ethernet gadget (RNDIS/CDC); the Linux kernel
#   auto-loads rndis_host/cdc_ether, NetworkManager DHCPs the new interface,
#   and Studio then talks TCP to the device IP (172.25.3.1 for V2 devices).
#   Wine uses host networking, so the app reaches it unmodified. The "Install
#   driver: RNDIS/CH340" toasts Studio shows on first launch are Windows
#   driver installers - ignore them, the kernel already has both drivers.
#
#   Device discovery (Wi-Fi and USB alike) is a V2 UDP handshake, decoded from
#   discover-worker.*.cjs in the 1.7.30 payload: Studio sends an AES-256-CBC
#   encrypted {type:"deviceFind",method:"request"} probe (key
#   "makeblockmakeblockmakeblock-2025", random 16-byte IV prepended) to four
#   groups, and a device answers with an encrypted "...method:response" packet
#   (key "makeblocsdbfjssjkkejqbcsdjfbqlla") echoing the requestId:
#     224.0.0.251:5353  / 224.0.0.252:5354   (mDNS scope, link-local, ttl 1)
#     239.0.1.251:25353 / 239.0.1.252:25354  (xTool private, site scope, ttl 4)
#   Studio joins all four groups to receive the replies, so those inbound UDP
#   ports are opened below (without them nftables drops the responses — UDP
#   multicast doesn't create usable conntrack entries).
#
#   For Wi-Fi specifically the two 239.0.1.x groups matter most: they are
#   site-scoped, so IGMP-snooping switches/APs only forward them to hosts that
#   have joined via IGMP. The NixOS nftables firewall accepts no L4 protocol
#   besides TCP/UDP/ICMP, so router IGMP membership queries were being dropped;
#   the kernel then stopped reporting its group memberships and the switch aged
#   this host out (~2 min), making the M2 appear in Studio's list on launch and
#   then vanish. The `ip protocol igmp accept` input rule below fixes that.
#   (The 224.0.0.x mDNS groups are link-local and always flooded, so USB — which
#   is a direct point-to-point link with no snooping switch — never needed it.)
#
#   Wi-Fi prerequisites the module can't enforce: the M2 must be joined to the
#   same L2 subnet as this host (use Studio's "Connect device -> Wi-Fi" wizard
#   over USB once to hand the machine your SSID/pass), and the AP must allow
#   client-to-client traffic (many "guest"/AP-isolation SSIDs silently block the
#   multicast + the TCP control connection). For validating the host/firewall
#   side without hardware, this module also installs `xtool-m2-emulator`
#   (m2-emulator.mjs) — run it on any host on the subnet and it
#   answers the discovery handshake as a fake M2.
#
# State follows the XDG base-dir spec:
#   $XDG_DATA_HOME/xtool-studio/wine   the 64-bit wineprefix (data); projects
#                                      and materials end up in its
#                                      drive_c/users/<user>/AppData/Roaming/
#   $XDG_STATE_HOME/xtool-studio/      the run log + apply-once stamps (state)
# defaulting to ~/.local/share and ~/.local/state. XTOOL_STUDIO_HOME overrides
# the data base for back-compat.
#
# The stdout/stderr redirect in the launcher is load-bearing, not cosmetic:
#   Studio's Electron main process lazily creates process.stdout/stderr the
#   first time it logs, via node's createWritableStdioStream(fd). When that fd
#   is a pipe (the usual case for desktop/session launchers, and for Bottles),
#   node wraps it with `new net.Socket({fd})`, which under Wine throws EBADF
#   and pops the fatal dialog:
#     "A JavaScript error occurred in the main process
#      Error: open EBADF ... at createWritableStdioStream"
#   A regular file or a real console takes a different, working code path, so
#   the launcher points both streams at a log file (and stdin at /dev/null).
#   This is why running via Bottles does NOT help — Bottles launches detached
#   with piped stdio and hits the exact same crash. Verified 2026-07 with an
#   A/B test on an identical prefix (pipe: crash; file: launches to the editor).
#
# Sandboxing (programs.xtool-studio.sandbox, default "bubblewrap"):
#   The launcher confines the untrusted vendor binary. Two backends ship; set
#   the option to "none" to disable confinement entirely.
#
#   "bubblewrap" (default): wine is wrapped in bwrap, baked straight into the
#   launcher. Preferred because bwrap uses unprivileged user namespaces (no
#   setuid-root helper — firejail's setuid binary is a recurring local-privesc
#   CVE source, usable by every process on the system once installed), needs no
#   NixOS module, and expresses the whole policy as explicit bind arguments
#   here. Verified available on this host: user.max_user_namespaces is
#   unrestricted and nothing in hardening.nix disables userns.
#
#   "firejail": for hosts that already standardise on firejail for their other
#   GUI apps. Turns on programs.firejail and wraps the (non-bwrap) launcher with
#   firejail.profile. Firejail profiles lean on include files that drift
#   between releases (0.9.80 folded disable-passwdmgr.inc into disable-common.inc,
#   for instance), so the profile is pinned to what ships today.
#
#   What either sandbox must allow, and why:
#     - host network namespace (NOT unshared): M2 discovery is LAN multicast
#       and a TCP control socket; a private netns kills both;
#     - /nix/store + system config read-only, GPU userspace (/run/opengl-driver)
#       + /dev/dri (and /dev/nvidia* under the proprietary driver) so accel
#       doesn't silently fall back to CPU;
#     - $HOME reduced to the writable XDG data + state dirs (the wineprefix
#       under ~/.local/share/xtool-studio and log/stamps under
#       ~/.local/state/xtool-studio) plus read-only Documents/Downloads/
#       Pictures/Desktop/Projects + font dirs for importing artwork;
#     - display transport: X11/XWayland (the X11 socket + XAUTHORITY cookie)
#       is the default path — wine 11's winewayland.drv shows a white window
#       with Studio's Chromium, see the wineRegistry note — with the Wayland
#       socket (in XDG_RUNTIME_DIR) kept bound so `DISPLAY= xtool-studio` can
#       opt into the native Wayland driver; no D-Bus (a Windows Electron
#       under Wine never speaks it);
#     - all other namespaces unshared, all caps dropped, no new-session TTY.
#   Deliberately NOT restricted in either: memory W^X (V8's JIT and Wine's
#   codegen both need it) and the inherited environment (clearing it breaks
#   DISPLAY/session lookup for a marginal secrecy gain).
#
# Updating: run `xtool-studio-update` (installed with this module; source in
# ./update.sh) from the root of this repo — it rewrites version + url + hash
# below in place. Current installer URL comes from
#   https://api.xtool.com/efficacy/v1/data/type/atomm_studio_version/items
# (the same endpoint the download page uses; the path contains a random UUID
# so it cannot be derived from the version number).

{ config, pkgs, lib, ... }:

let
  cfg = config.programs.xtool-studio;

  version = "1.7.30";

  installer = pkgs.fetchurl {
    url = "https://storage.atomm.com/efficacy/atomm-package/prod/packages/109/ef6aeb53-66ee-455c-a8ad-8a0e9486857e/xTool-Studio-x64-${version}.exe";
    hash = "sha256-62BwXAS3SjgkdIwxZVpd7qH1oHLRZFj+CMxj30P3H4s=";
  };

  # 64-bit-only Wine is sufficient: the payload is x64 and pulls no 32-bit
  # dependencies. wineboot in the launcher initializes the prefix on first run.
  wine = pkgs.wine64;

  # Fonts for the wineprefix (fixes the missing-glyph / blank-label UI).
  # Chromium/Electron on Windows renders all text via DirectWrite, and Wine's
  # DirectWrite builds its system font collection SOLELY from the registry key
  #   HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts
  # (dlls/dwrite/main.c create_system_path_list, verified in wine 11.0) — it
  # never scans C:\windows\Fonts, and host fontconfig fonts are visible to
  # Wine's GDI alone. Each font therefore needs BOTH a link in
  # C:\windows\Fonts (the stable path the registry values resolve against,
  # plus GDI) and a value under that key (generated into wineRegistry below).
  # Without the registry entries DirectWrite's only fonts are the handful Wine
  # itself registers (Tahoma etc.), so Studio could render its own bundled
  # webfonts (Inter, its "iconfont" icon face) and Tahoma but drew every other
  # family as blank glyphless runs — blank buttons/dropdowns/inputs anywhere
  # the CSS resolves to a system font, with Blink even failing to find a
  # last-resort fallback ("remote_font_face_source.cc ... NOTREACHED" in the
  # app log). Diagnosed live via --remote-debugging-port: canvas fillText
  # painted 0 px for every farm family but 652 px for Wine's registered
  # Tahoma, and registry-registering the farm fixed all of them.
  #
  # A bare prefix also has no CJK at all for Studio's Chinese strings.
  # One flat directory
  # of font files the launcher links into the prefix: Noto Sans is the primary
  # UI face (see the FontSubstitutes below) with the rest of the Noto set for
  # wide script coverage, Noto Color Emoji supplies emoji (CBDT/CBLC bitmap
  # color tables — Chromium's Skia consumes those directly, so emoji render in
  # color without any DirectWrite COLR support needed), corefonts gives real
  # Arial/Verdana/Times for content that asks for them by name (unfree but
  # redistributable; allowUnfree is set repo-wide in common.nix), Liberation +
  # DejaVu add metric-compatible sans/serif/mono and monochrome symbol glyphs,
  # Noto Sans CJK SC covers Chinese.
  wineFonts =
    pkgs.runCommand "xtool-studio-wine-fonts"
      {
        fontPackages = [
          pkgs.noto-fonts
          pkgs.noto-fonts-color-emoji
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

  # One-shot prefix registry setup, applied by the launcher (REGEDIT4 / ANSI —
  # all values here are pure ASCII, which Wine's regedit parses as-is):
  #
  #   Drivers\Graphics = "x11,wayland" — X11/XWayland first, Wine's native
  #   Wayland driver (winewayland.drv) only as the fallback when no X server
  #   is reachable. Wine tries the drivers in order and uses the first that
  #   initialises. Wayland-first was tried and reverted: wine 11's
  #   winewayland presents Studio's Chromium as a solid white window after
  #   the splash (the renderer itself is healthy — remote-debugging shows the
  #   pages fully loaded — the frames just never reach the surface), so the
  #   deprecated-but-working X11 path stays the default. Native Wayland
  #   remains opt-in for testing newer wine: run `DISPLAY= xtool-studio`
  #   (empty DISPLAY makes x11 bail so wayland takes over; the launcher's
  #   bwrap sandbox already binds the Wayland socket).
  #
  #   FontSubstitutes — map the Windows family names Studio/Chromium asks for
  #   onto fonts actually present in wineFonts. The Latin UI faces (Segoe UI is
  #   the Windows UI default; MS Shell Dlg/Tahoma/Microsoft Sans Serif are the
  #   GDI dialog defaults) all resolve to Noto Sans for a consistent, nicer
  #   look; Segoe UI Emoji goes to Noto Color Emoji (Segoe UI Symbol stays on
  #   DejaVu Sans — it is mostly non-emoji symbols like arrows and geometric
  #   shapes, which Noto Color Emoji does not carry); the YaHei/SimSun/PingFang
  #   set covers the Chinese locale CSS stacks.
  wineRegistryBase = pkgs.writeText "xtool-studio-wine-base.reg" ''
    REGEDIT4

    [HKEY_CURRENT_USER\Software\Wine\Drivers]
    "Graphics"="x11,wayland"

    [HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]
    "Segoe UI"="Noto Sans"
    "Segoe UI Semibold"="Noto Sans"
    "MS Shell Dlg"="Noto Sans"
    "MS Shell Dlg 2"="Noto Sans"
    "Tahoma"="Noto Sans"
    "Microsoft Sans Serif"="Noto Sans"
    "Segoe UI Emoji"="Noto Color Emoji"
    "Segoe UI Symbol"="DejaVu Sans"
    "Microsoft YaHei"="Noto Sans CJK SC"
    "Microsoft YaHei UI"="Noto Sans CJK SC"
    "SimSun"="Noto Sans CJK SC"
    "NSimSun"="Noto Sans CJK SC"
    "SimHei"="Noto Sans CJK SC"
    "PingFang SC"="Noto Sans CJK SC"
  '';

  # Final .reg the launcher applies: the static rules above plus one
  # HKLM ...\CurrentVersion\Fonts value per farm font, which is what makes the
  # farm visible to DirectWrite at all (see the wineFonts note). Values are
  # absolute Z:\nix\store\... paths to the fully-resolved font files — the
  # same way Wine registers its own bundled Tahoma — rather than the
  # C:\windows\Fonts links. Because this file embeds the wineFonts store path,
  # any change to the font set yields a new .reg store path and the launcher's
  # stamp check re-applies it automatically. regedit only adds/overwrites
  # values; entries for fonts later dropped from the farm go stale, which is
  # harmless (dwrite skips files it cannot open, with a WARN).
  wineRegistry = pkgs.runCommand "xtool-studio-wine.reg" { } ''
    {
      cat ${wineRegistryBase}
      printf '\n%s\n' '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\Fonts]'
      for f in ${wineFonts}/*; do
        b=$(basename "$f")
        real=$(readlink -f "$f")
        printf '"%s (TrueType)"="Z:%s"\n' "''${b%.*}" "''${real//\//\\\\}"
      done
    } >$out
  '';

  # The extracted Windows application tree (Electron app + native tools). Kept
  # as its own derivation so the launcher can reference it by store path
  # without makeWrapper (makeWrapper cannot redirect the child's stdio, which
  # is exactly what we need — see the EBADF note in the header).
  xtool-studio-unwrapped = pkgs.stdenvNoCC.mkDerivation {
    pname = "xtool-studio-unwrapped";
    inherit version;
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.p7zip ];
    installPhase = ''
      runHook preInstall

      # The .exe is NSIS; the actual application is a solid 7z inside it.
      7z e ${installer} '$PLUGINSDIR/app-64.7z' -opayload
      mkdir -p $out
      7z x payload/app-64.7z -o$out

      # Neuter the electron-builder auto-updater: the install dir is a
      # read-only store path, so an attempted self-update could only fail.
      rm -f $out/resources/app-update.yml

      runHook postInstall
    '';
    meta.license = lib.licenses.unfree;
  };

  # Shared launcher preamble: prefix env, first-run wineboot, and font setup.
  # Under bubblewrap this runs before the sandbox (trusted nixpkgs wine writing
  # only into the state/data dirs); under firejail the whole launcher is already
  # confined.
  #
  # XDG split (see spec): the wineprefix is user *data* (it holds projects under
  # AppData) so it lives in XDG_DATA_HOME; the log and the "have I applied this
  # store path yet" stamps are *state* and live in XDG_STATE_HOME. Legacy
  # XTOOL_STUDIO_HOME still overrides the data base for anyone who set it.
  launcherPreamble = ''
    dataHome="''${XTOOL_STUDIO_HOME:-''${XDG_DATA_HOME:-$HOME/.local/share}/xtool-studio}"
    stateHome="''${XDG_STATE_HOME:-$HOME/.local/state}/xtool-studio"
    export WINEPREFIX="$dataHome/wine"
    export WINEDEBUG="''${WINEDEBUG:--all}"
    # DLL overrides, ';'-joined:
    #   winemenubuilder.exe=d  don't scatter Start-menu .desktop files
    #   mscoree=  / mshtml=    disable the Mono/.NET and Gecko auto-installers.
    #     On a fresh prefix wineboot otherwise pops a modal "Wine Mono
    #     Installer" that blocks startup while it tries to download Mono.
    #     Studio is Electron + native code (its own Chromium, no .NET), so
    #     neither runtime is used; disabling them keeps first run offline-safe.
    export WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree=;mshtml=;''${WINEDLLOVERRIDES:-}"

    mkdir -p "$dataHome" "$stateHome"
    if [ ! -f "$WINEPREFIX/system.reg" ]; then
      wineboot -u >/dev/null 2>&1 || true
    fi

    # Fonts (see the wineFonts note above): refresh the nix-managed links in
    # the prefix's Fonts dir on every launch so font upgrades propagate,
    # sweeping stale store links from previous generations first.
    fontdir="$WINEPREFIX/drive_c/windows/Fonts"
    mkdir -p "$fontdir"
    find "$fontdir" -maxdepth 1 -type l -lname '/nix/store/*' -delete
    ln -sft "$fontdir" ${wineFonts}/*

    # Prefix registry (graphics driver + font substitutes + the DirectWrite
    # font registration that makes the farm renderable at all; see
    # wineRegistry above): re-applied only when its store path changes.
    #
    # The trailing `wineserver -w` is load-bearing: under the bubblewrap
    # sandbox the app cannot reach this preamble's wineserver (bwrap unshares
    # pid/ipc and mounts a private /tmp, which is where the server socket
    # lives), so it starts a second wineserver that reads system.reg from
    # disk. Without waiting for this server to save and exit, the app's server
    # loads a stale registry and its own final save then discards everything
    # regedit just applied — which is why these registry tweaks historically
    # never took effect under the default sandbox. The stamp is only written
    # after a confirmed flush for the same reason.
    if [ "$(cat "$stateHome/.wine-registry" 2>/dev/null || true)" != "${wineRegistry}" ]; then
      if wine regedit /S "${wineRegistry}" >/dev/null 2>&1 && wineserver -w; then
        printf '%s' '${wineRegistry}' >"$stateHome/.wine-registry"
      fi
    fi

    # HiDPI: map a scale factor to Wine's LogPixels (96 = 100%, 144 = 150%,
    # 192 = 200%). Chromium/Electron read the Windows system DPI, so this scales
    # Studio's entire UI. Precedence: XTOOL_STUDIO_SCALE env override, then the
    # programs.xtool-studio.scale option, then the desktop's GDK_SCALE hint;
    # unset leaves Wine at its default. On Wayland winewayland.drv additionally
    # honours the compositor's per-output scale.
    scale="''${XTOOL_STUDIO_SCALE:-${lib.optionalString (cfg.scale != null) cfg.scale}}"
    scale="''${scale:-''${GDK_SCALE:-}}"
    if [ -n "$scale" ]; then
      logpixels="$(awk -v s="$scale" 'BEGIN { printf "%d", (96 * s) + 0.5 }')"
      if [ "$(cat "$stateHome/.logpixels" 2>/dev/null || true)" != "$logpixels" ]; then
        # wineserver -w: flush before stamping, see the registry note above.
        if wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD \
          /d "$logpixels" /f >/dev/null 2>&1 && wineserver -w; then
          printf '%s' "$logpixels" >"$stateHome/.logpixels"
        fi
      fi
    fi

    # GPU workaround: Chromium's GPU compositor misbehaves under Wine (ANGLE ->
    # wined3d), painting composited layers — button backgrounds/gradients and
    # the labels drawn on them — as flat unlabeled rectangles while ordinary
    # document text is fine. --disable-gpu-compositing rasterizes + composites
    # the page on the CPU (WebGL/canvas stay GPU-backed, read back into the
    # software frame), the least-invasive switch that fixes those blank layers.
    # Override at runtime via XTOOL_STUDIO_GPU_FLAGS if needed — escalation
    # path: "--disable-gpu", then "--disable-gpu --disable-software-rasterizer";
    # set it to a single space to pass no GPU flag and retest full GPU.
    read -ra gpu_flags <<<"''${XTOOL_STUDIO_GPU_FLAGS:---disable-gpu-compositing}"
  '';

  # stdio -> regular file is load-bearing, not cosmetic (see the EBADF note in
  # the header): whatever wraps it inherits these fds and hands them to the
  # child unchanged. Truncated each launch so it stays small but still captures
  # the most recent run for troubleshooting.
  #
  # --no-sandbox: Chromium's Windows sandbox primitives don't exist under Wine.
  # gpu_flags: see the GPU workaround note in launcherPreamble.
  studioExe = ''wine "${xtool-studio-unwrapped}/xTool Studio.exe" --no-sandbox "''${gpu_flags[@]}" "$@"'';
  redirect = ''>"$stateHome/xtool-studio.log" 2>&1 </dev/null'';

  # No-op / firejail path: run the app directly. When sandbox = "firejail" the
  # programs.firejail wrapper (below) confines this whole launcher externally.
  plainExec = ''
    exec ${studioExe} ${redirect}
  '';

  # Bubblewrap sandbox (see the Sandboxing note in the header). Host net
  # namespace is deliberately shared — M2 discovery is LAN multicast and dies
  # inside a private netns; every other namespace is unshared and all
  # capabilities are dropped automatically inside the user namespace.
  bwrapExec = ''
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
      # /run/systemd/resolve/stub-resolv.conf (systemd-resolved), and glibc NSS
      # prefers the nscd socket at /run/nscd/socket (NixOS runs nscd/nsncd by
      # default). Binding /etc alone leaves both dangling, so every hostname
      # lookup fails and the app's cloud login times out.
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
    )

    # Read-only access to the usual art/import folders (skipped when absent),
    # plus fonts and the fontconfig cache for fast, correct text rendering.
    for d in Documents Downloads Pictures Desktop Projects .fonts ".local/share/fonts" ".cache/fontconfig"; do
      bwrap_args+=(--ro-bind-try "$HOME/$d" "$HOME/$d")
    done

    # Session runtime dir (the Wayland display socket — the preferred transport,
    # see wineRegistry — plus PulseAudio / PipeWire) and the X11 auth cookie for
    # the XWayland/X11 fallback; read-only, only if present. Env is inherited
    # (not cleared) so WAYLAND_DISPLAY / DISPLAY / XAUTHORITY / XDG_RUNTIME_DIR
    # reach the child unchanged.
    if [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
      bwrap_args+=(--ro-bind-try "$XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR")
    fi
    if [ -n "''${XAUTHORITY:-}" ]; then
      bwrap_args+=(--ro-bind-try "$XAUTHORITY" "$XAUTHORITY")
    fi

    exec bwrap "''${bwrap_args[@]}" \
      ${studioExe} \
      ${redirect}
  '';

  # writeShellApplication runs under `set -euo pipefail`; the trailing exec (with
  # its redirections) replaces the shell, so nothing after it matters.
  useBwrap = cfg.sandbox == "bubblewrap";
  launcher = pkgs.writeShellApplication {
    name = "xtool-studio";
    runtimeInputs = [
      wine # wine + wineboot on PATH
    ] ++ lib.optional useBwrap pkgs.bubblewrap; # bwrap (see header)
    text = launcherPreamble + (if useBwrap then bwrapExec else plainExec);
  };

  # Test helper: answers Studio's discovery handshake as a fake M2 so the
  # Wi-Fi/USB detection + firewall path can be validated without hardware.
  # Run it on any host on the same subnet, then start a scan in Studio.
  m2-emulator = pkgs.writeShellApplication {
    name = "xtool-m2-emulator";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''exec node ${./m2-emulator.mjs} "$@"'';
  };

  # Maintainer tool (see the Updating note in the header): queries xTool's
  # version API for the newest Windows x64 installer, prefetches it, and
  # rewrites version/url/hash above in place. Run it from the root of a
  # checkout of this repo (or pass the module path as the first argument).
  # writeShellApplication shellchecks the script at build time.
  updater = pkgs.writeShellApplication {
    name = "xtool-studio-update";
    runtimeInputs = with pkgs; [
      curl
      jq
      nix
      coreutils
      gnused
      gawk
      gnugrep
    ];
    text = builtins.readFile ./update.sh;
  };

  xtool-studio = pkgs.stdenvNoCC.mkDerivation {
    pname = "xtool-studio";
    inherit version;

    dontUnpack = true;

    nativeBuildInputs = with pkgs; [
      imagemagick # ext.ico -> hicolor PNGs
      copyDesktopItems
    ];

    desktopItems = [
      (pkgs.makeDesktopItem {
        name = "xtool-studio";
        exec = "xtool-studio %U";
        icon = "xtool-studio";
        desktopName = "xTool Studio";
        comment = "Design and control software for xTool laser cutters (Wine)";
        categories = [
          "Graphics"
          "Engineering"
        ];
        mimeTypes = [
          "application/x-xcs"
          "application/x-xs"
        ];
      })
    ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin
      ln -s ${launcher}/bin/xtool-studio $out/bin/xtool-studio

      # NB: the [0] frame selector must be quoted — stdenv enables nullglob,
      # which would otherwise silently delete the unmatched-glob argument.
      for size in 32 64 128 256; do
        mkdir -p $out/share/icons/hicolor/"$size"x"$size"/apps
        magick "${xtool-studio-unwrapped}/resources/ext.ico[0]" \
          -resize "$size"x"$size" \
          $out/share/icons/hicolor/"$size"x"$size"/apps/xtool-studio.png
      done

      runHook postInstall
    '';

    meta = {
      description = "xTool Studio laser cutter software (Windows build run via Wine)";
      homepage = "https://www.xtool.com/pages/software";
      license = lib.licenses.unfree;
      platforms = [ "x86_64-linux" ];
      mainProgram = "xtool-studio";
    };
  };
in
{
  options.programs.xtool-studio.sandbox = lib.mkOption {
    type = lib.types.enum [
      "bubblewrap"
      "firejail"
      "none"
    ];
    default = "bubblewrap";
    description = ''
      How to confine the (proprietary, closed-source) xTool Studio binary; see
      the Sandboxing note at the top of this module.

      - "bubblewrap": wrap wine in bwrap, baked into the launcher. Default;
        unprivileged (user namespaces), no setuid helper.
      - "firejail": enable {option}`programs.firejail` and wrap the launcher
        with the bundled firejail.profile. Choose this if the host already
        standardises on firejail.
      - "none": run unconfined.
    '';
  };

  options.programs.xtool-studio.scale = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "1.5";
    description = ''
      HiDPI scale factor for the Studio UI, as a multiplier of 100% (e.g.
      "1.5" = 150%, "2" = 200%). Translated to Wine's LogPixels, which
      Chromium/Electron read as the system DPI. `null` leaves Wine at its
      default — on Wayland winewayland.drv follows the compositor's output
      scale, so an explicit value is mainly needed on X11 or to override.
      The `XTOOL_STUDIO_SCALE` environment variable overrides this at runtime.
    '';
  };

  config = {
    # The desktop file's bare `Exec=xtool-studio` resolves to `launcher` on
    # PATH. For "bubblewrap"/"none" that launcher is the whole story; for
    # "firejail" the firejail module builds a same-named wrapper with
    # meta.priority = -1 that shadows it and applies the profile.
    environment.systemPackages = [
      xtool-studio
      m2-emulator
      updater
    ];

    programs.firejail = lib.mkIf (cfg.sandbox == "firejail") {
      enable = true;
      wrappedBinaries.xtool-studio = {
        executable = "${xtool-studio}/bin/xtool-studio";
        profile = ./firejail.profile;
        extraArgs = [ "--quiet" ];
      };
    };

    # Device discovery multicast (see header). 5353 overlaps with avahi's mDNS
    # (desktop-common.nix already opens it via services.avahi.openFirewall);
    # listing it here keeps this module self-sufficient on non-desktop hosts.
    networking.firewall.allowedUDPPorts = [
      5353
      5354
      25353
      25354
    ];

    # Accept inbound IGMP membership queries. The NixOS nftables firewall
    # accepts no L4 protocols besides TCP/UDP/ICMP, so the periodic queries the
    # router multicasts fall through to the drop policy. The kernel then never
    # answers them, IGMP-snooping switches/APs age the host out of their
    # forwarding tables (~2 min), and xTool's private discovery groups
    # (239.0.1.251/252 — site scope, snooped, unlike the always-flooded
    # 224.0.0.x mDNS groups) stop being delivered: the M2 appears in Studio's
    # Wi-Fi list right after launch and later vanishes. Accepting the query lets
    # the kernel keep the group memberships alive.
    #
    # Scoped to type membership-query only (all IGMP versions use type 0x11 for
    # queries) — that is the sole packet the kernel must see; inbound reports and
    # leave-group messages from other hosts stay dropped. The igmp expression
    # carries an implicit IPv4 match, so this stays inert on IPv6.
    networking.firewall.extraInputRules = ''
      igmp type membership-query accept
    '';
  };
}
