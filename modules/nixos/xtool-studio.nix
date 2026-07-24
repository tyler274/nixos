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
#   (xtool-studio-m2-emulator.mjs) — run it on any host on the subnet and it
#   answers the discovery handshake as a fake M2.
#
# State lives in ~/.local/share/xtool-studio/wine (a dedicated 64-bit
# wineprefix); projects, logs, and materials end up under
#   <prefix>/drive_c/users/<user>/AppData/Roaming/xTool Studio/
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
# Updating: bump version + url + hash. Current installer URL comes from
#   https://api.xtool.com/efficacy/v1/data/type/atomm_studio_version/items
# (the same endpoint the download page uses; the path contains a random UUID
# so it cannot be derived from the version number).

{ pkgs, lib, ... }:

let
  version = "1.7.30";

  installer = pkgs.fetchurl {
    url = "https://storage.atomm.com/efficacy/atomm-package/prod/packages/109/ef6aeb53-66ee-455c-a8ad-8a0e9486857e/xTool-Studio-x64-${version}.exe";
    hash = "sha256-62BwXAS3SjgkdIwxZVpd7qH1oHLRZFj+CMxj30P3H4s=";
  };

  # 64-bit-only Wine is sufficient: the payload is x64 and pulls no 32-bit
  # dependencies. wineboot in the launcher initializes the prefix on first run.
  wine = pkgs.wine64;

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

  launcher = pkgs.writeShellApplication {
    name = "xtool-studio";
    runtimeInputs = [ wine ]; # wine + wineboot on PATH
    # writeShellApplication runs under `set -euo pipefail`; the trailing exec
    # (with its redirections) replaces the shell, so nothing after it matters.
    text = ''
      statedir="''${XTOOL_STUDIO_HOME:-''${XDG_DATA_HOME:-$HOME/.local/share}/xtool-studio}"
      export WINEPREFIX="$statedir/wine"
      export WINEDEBUG="''${WINEDEBUG:--all}"
      # DLL overrides, ';'-joined:
      #   winemenubuilder.exe=d  don't scatter Start-menu .desktop files
      #   mscoree=  / mshtml=    disable the Mono/.NET and Gecko auto-installers.
      #     On a fresh prefix wineboot otherwise pops a modal "Wine Mono
      #     Installer" that blocks startup while it tries to download Mono.
      #     Studio is Electron + native code (its own Chromium, no .NET), so
      #     neither runtime is used; disabling them keeps first run offline-safe.
      export WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree=;mshtml=;''${WINEDLLOVERRIDES:-}"
      mkdir -p "$WINEPREFIX"
      if [ ! -f "$WINEPREFIX/system.reg" ]; then
        wineboot -u >/dev/null 2>&1 || true
      fi

      # stdio -> regular file is required, not optional: see the EBADF note in
      # the module header. Truncated each launch so it stays small but still
      # captures the most recent run for troubleshooting.
      exec wine "${xtool-studio-unwrapped}/xTool Studio.exe" --no-sandbox "$@" \
        >"$statedir/xtool-studio.log" 2>&1 </dev/null
    '';
  };

  # Test helper: answers Studio's discovery handshake as a fake M2 so the
  # Wi-Fi/USB detection + firewall path can be validated without hardware.
  # Run it on any host on the same subnet, then start a scan in Studio.
  m2-emulator = pkgs.writeShellApplication {
    name = "xtool-m2-emulator";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''exec node ${./xtool-studio-m2-emulator.mjs} "$@"'';
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
  environment.systemPackages = [
    xtool-studio
    m2-emulator
  ];

  # Device discovery multicast (see header). 5353 overlaps with avahi's mDNS
  # (desktop-common.nix already opens it via services.avahi.openFirewall);
  # listing it here keeps this module self-sufficient on non-desktop hosts.
  networking.firewall.allowedUDPPorts = [
    5353
    5354
    25353
    25354
  ];

  # Accept inbound IGMP membership queries. The NixOS nftables firewall accepts
  # no L4 protocols besides TCP/UDP/ICMP, so the periodic queries the router
  # multicasts fall through to the drop policy. The kernel then never answers
  # them, IGMP-snooping switches/APs age the host out of their forwarding
  # tables (~2 min), and xTool's private discovery groups (239.0.1.251/252 —
  # site scope, snooped, unlike the always-flooded 224.0.0.x mDNS groups) stop
  # being delivered: the M2 appears in Studio's Wi-Fi list right after launch
  # and later vanishes. Accepting the query lets the kernel keep the group
  # memberships alive.
  #
  # Scoped to type membership-query only (all IGMP versions use type 0x11 for
  # queries) — that is the sole packet the kernel must see; inbound reports and
  # leave-group messages from other hosts stay dropped. The igmp expression
  # carries an implicit IPv4 match, so this stays inert on IPv6.
  networking.firewall.extraInputRules = ''
    igmp type membership-query accept
  '';
}
