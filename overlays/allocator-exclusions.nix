# Chromium-family and Mozilla browsers ship their own allocators
# (PartitionAlloc, mozjemalloc) and cannot coexist with a system-wide
# malloc preloaded via /etc/ld-nix.so.preload (environment.memoryAllocator).
#
# Verified 2026-08 on this host, injecting that preload with bwrap so the
# test matches the NixOS mechanism rather than LD_PRELOAD (which content
# processes can drop):
#
#   Edge / Electron (Signal, Bitwarden, Pocket Casts)
#     libc / graphene / graphene-light  — start
#     mimalloc                          — SIGSEGV (Edge) or SIGTRAP (Electron)
#   Firefox / Thunderbird (firefox-bin, thunderbird-bin)
#     all four                          — headless start; still wrapped
#                                         because mozjemalloc vs ld.so.preload
#                                         is a known class of content-process
#                                         crashes (scudo/graphene on other
#                                         versions) and the wrap is a no-op
#                                         when the preload file is absent.
#
# Hiding the preload in a mount namespace (empty file bind-mounted over
# /etc/ld-nix.so.preload) restores Edge and Signal under mimalloc. Package
# overrides can't opt a derivation out of ld.so.preload at build time — the
# file is applied by glibc at runtime — so each launcher is wrapped with
# bubblewrap. Firejail's --blacklist of the same path covers the
# programs.firejail wrappers (see desktop-common.nix); without it, firejail
# noroot blocks the inner bwrap.
#
# Do not wrap `electron` / `electron_N`: leaf apps (Signal, Bitwarden, …)
# exec those binaries, so wrapping the launcher is enough — the child
# inherits the mount namespace. Wrapping electron itself also catches
# Mullvad's GUI, whose bwrap user namespace cannot talk to mullvad-daemon
# on /run/mullvad-vpn.
#
# Do not wrap sleepy-launcher (or other aagl launchers). They already run
# inside steam-run's FHS bwrap, whose tmpfs /etc omits ld-nix.so.preload,
# and a second user namespace breaks Wine on NVIDIA (udev, drive letters).
#
# The wrap is allocator-agnostic: switching provider to graphene-hardened
# or graphene-hardened-light does not need another overlay change.
final: prev:
let
  inherit (prev) lib;

  emptyPreload = prev.writeText "empty-ld-nix.so.preload" "";

  # NixOS installs /etc/ld-nix.so.preload as a symlink into /etc/static (and
  # from there into the store). bwrap --ro-bind onto a symlink dest fails
  # with "Can't create file at /etc/ld-nix.so.preload: No such file or
  # directory". Bind the resolved regular file instead; glibc follows the
  # symlink and then reads emptiness.
  wrapperTemplate = prev.writeText "hide-system-malloc.sh" ''
    #!${prev.runtimeShell}
    empty=${emptyPreload}
    real="@real@"

    if [ ! -e /etc/ld-nix.so.preload ] && [ ! -L /etc/ld-nix.so.preload ]; then
      exec "$real" "$@"
    fi

    binds=()
    add_bind() {
      local f=$1
      [[ -n $f && -f $f && ! -L $f ]] || return 0
      local b
      for b in "''${binds[@]}"; do
        [[ $b == "$f" ]] && return 0
      done
      binds+=("$f")
    }

    add_bind /etc/ld-nix.so.preload
    add_bind "$(readlink -f /etc/ld-nix.so.preload 2>/dev/null || true)"
    add_bind /etc/static/ld-nix.so.preload
    add_bind "$(readlink -f /etc/static/ld-nix.so.preload 2>/dev/null || true)"

    if (( ''${#binds[@]} == 0 )); then
      exec "$real" "$@"
    fi

    args=(--bind / / --dev-bind /dev /dev --proc /proc)
    for f in "''${binds[@]}"; do
      args+=(--ro-bind "$empty" "$f")
    done
    args+=(--die-with-parent)

    exec ${lib.getExe prev.bubblewrap} "''${args[@]}" "$real" "$@"
  '';

  # Preserve callPackage/wrapFirefox surface so later overlays and HM
  # (`package.override`, chromium.sandbox, firefox-bin.unwrapped) keep working
  # on top of the symlinkJoin.
  keepInterface =
    orig: wrapped:
    wrapped
    // lib.optionalAttrs (orig ? override) {
      override = args: hideSystemMalloc (orig.override args);
    }
    // lib.optionalAttrs (orig ? overrideAttrs) {
      overrideAttrs = f: hideSystemMalloc (orig.overrideAttrs f);
    }
    // lib.optionalAttrs (orig ? sandbox) { inherit (orig) sandbox; }
    // lib.optionalAttrs (orig ? browser) { inherit (orig) browser; }
    // lib.optionalAttrs (orig ? unwrapped) { inherit (orig) unwrapped; };

  hideSystemMalloc =
    pkg:
    if !lib.isDerivation pkg then
      pkg
    else
      let
        pname = pkg.pname or (lib.getName pkg);
        version = pkg.version or "";
        wrapped = prev.symlinkJoin {
          name = "${pname}-libc-malloc${lib.optionalString (version != "") "-${version}"}";
          inherit (pkg) pname version;
          paths = [ pkg ];
          passthru = pkg.passthru or { };
          meta = pkg.meta or { };
          postBuild = ''
            shopt -s nullglob
            for bin in "$out"/bin/*; do
              [ -e "$bin" ] || continue
              [ -d "$bin" ] && continue
              case "$(basename "$bin")" in
                *sandbox*) continue ;;
              esac
              [ -x "$bin" ] || continue
              real=$(readlink -f "$bin")
              rm -f "$bin"
              substitute ${wrapperTemplate} "$bin" --subst-var-by real "$real"
              chmod +x "$bin"
            done

            # Edge (and some Chromium builds) bake absolute store paths into
            # .desktop Exec= lines. aagl's wrapAAGL points Exec at the inner
            # steam-run script, not the symlinkJoin out path, so also rewrite
            # resolved bin paths.
            if [ -d "$out/share" ]; then
              find "$out/share" \( -name '*.desktop' -o -name '*.service' \) -print0 \
                | while IFS= read -r -d "" f; do
                    [ -e "$f" ] || continue
                    cp -L --remove-destination "$f" "$f.tmp"
                    substituteInPlace "$f.tmp" --replace-quiet ${pkg} "$out" || true
                    for origbin in ${pkg}/bin/*; do
                      [ -e "$origbin" ] || continue
                      name=$(basename "$origbin")
                      orig=$(readlink -f "$origbin")
                      substituteInPlace "$f.tmp" --replace-quiet "$orig" "$out/bin/$name" || true
                    done
                    mv "$f.tmp" "$f"
                  done
            fi
          '';
        };
      in
      keepInterface pkg wrapped;
in
# Do not filterAttrs over `prev` — that forces every nixpkgs attribute.
# Wrap leaf apps, not the electron interpreter (see header). New Electron
# apps that ship their own launcher script should be added here.
lib.genAttrs [
  "firefox"
  "firefox-bin"
  "thunderbird"
  "thunderbird-bin"
  "chromium"
  "microsoft-edge"
  "discord"
  "signal-desktop"
  "bitwarden-desktop"
  "pocket-casts"
] (n: hideSystemMalloc prev.${n})
