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
#   native pieces working. Verified: the 1.7.30 installer payload runs under
#   wine 11 (64-bit) — region select, ToS, home screen, and the editor canvas
#   all render and the USB-detect and algo services start.
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
#   Device discovery (Wi-Fi and USB alike) is multicast:
#     224.0.0.251:5353 / 224.0.0.252:5354   (mDNS, link-local)
#     239.0.1.251:25353 / 239.0.1.252:25354 (xTool private groups)
#   so those UDP ports are opened below; without them nftables drops the
#   responses (UDP multicast queries don't create usable conntrack entries).
#
# State lives in ~/.local/share/xtool-studio/wine (a dedicated 64-bit
# wineprefix); projects, logs, and materials end up under
#   <prefix>/drive_c/users/<user>/AppData/Roaming/xTool Studio/
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
  # dependencies. wineboot below initializes the prefix on first run.
  wine = pkgs.wine64;

  xtool-studio = pkgs.stdenvNoCC.mkDerivation {
    pname = "xtool-studio";
    inherit version;

    dontUnpack = true;

    nativeBuildInputs = with pkgs; [
      p7zip # NSIS installer and inner app-64.7z extraction
      imagemagick # ext.ico -> hicolor PNGs
      makeWrapper
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

      # The .exe is NSIS; the actual application is a solid 7z inside it.
      7z e ${installer} '$PLUGINSDIR/app-64.7z' -opayload
      mkdir -p $out/share/xtool-studio
      7z x payload/app-64.7z -o$out/share/xtool-studio

      # Neuter the electron-builder auto-updater: the install dir is a
      # read-only store path, so an attempted self-update could only fail.
      rm -f $out/share/xtool-studio/resources/app-update.yml

      # NB: the [0] frame selector must be quoted — stdenv enables nullglob,
      # which would otherwise silently delete the unmatched-glob argument.
      for size in 32 64 128 256; do
        mkdir -p $out/share/icons/hicolor/"$size"x"$size"/apps
        magick "$out/share/xtool-studio/resources/ext.ico[0]" \
          -resize "$size"x"$size" \
          $out/share/icons/hicolor/"$size"x"$size"/apps/xtool-studio.png
      done

      mkdir -p $out/bin
      makeWrapper ${lib.getExe' wine "wine"} $out/bin/xtool-studio \
        --run 'export WINEPREFIX="''${XTOOL_STUDIO_HOME:-''${XDG_DATA_HOME:-$HOME/.local/share}/xtool-studio}/wine"' \
        --run 'export WINEDEBUG="''${WINEDEBUG:--all}"' \
        --run 'export WINEDLLOVERRIDES="winemenubuilder.exe=d;''${WINEDLLOVERRIDES:-}"' \
        --run 'mkdir -p "$WINEPREFIX"' \
        --run '[ -f "$WINEPREFIX/system.reg" ] || ${lib.getExe' wine "wineboot"} -u >/dev/null 2>&1' \
        --add-flags "\"$out/share/xtool-studio/xTool Studio.exe\"" \
        --add-flags "--no-sandbox"

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
  environment.systemPackages = [ xtool-studio ];

  # Device discovery multicast (see header). 5353 overlaps with avahi's mDNS
  # (desktop-common.nix already opens it via services.avahi.openFirewall);
  # listing it here keeps this module self-sufficient on non-desktop hosts.
  networking.firewall.allowedUDPPorts = [
    5353
    5354
    25353
    25354
  ];
}
