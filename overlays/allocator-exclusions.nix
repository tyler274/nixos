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
# The wrap is allocator-agnostic: switching provider to graphene-hardened
# or graphene-hardened-light does not need another overlay change.
final: prev:
let
  inherit (prev) lib;

  emptyPreload = prev.writeText "empty-ld-nix.so.preload" "";

  wrapperTemplate = prev.writeText "hide-system-malloc.sh" ''
    #!${prev.runtimeShell}
    if [ -s /etc/ld-nix.so.preload ]; then
      exec ${lib.getExe prev.bubblewrap} \
        --bind / / \
        --dev-bind /dev /dev \
        --proc /proc \
        --ro-bind ${emptyPreload} /etc/ld-nix.so.preload \
        --die-with-parent \
        "@real@" "$@"
    fi
    exec "@real@" "$@"
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
            # .desktop Exec= lines; rewrite those so the launcher hits the
            # wrapped bin instead of the original.
            if [ -d "$out/share" ]; then
              find "$out/share" \( -name '*.desktop' -o -name '*.service' \) -print0 \
                | while IFS= read -r -d "" f; do
                    cp -L --remove-destination "$f" "$f.tmp"
                    substituteInPlace "$f.tmp" --replace-quiet ${pkg} "$out" || true
                    mv "$f.tmp" "$f"
                  done
            fi
          '';
        };
      in
      keepInterface pkg wrapped;
in
# Do not filterAttrs over `prev` — that forces every nixpkgs attribute.
# Wrap the electron alias plus the versioned slots this config actually
# runs (42 = pocket-casts, 43 = signal/bitwarden). New Electron apps that
# pin some other slot need their slot added here (or wrap the leaf app).
lib.genAttrs [
  "electron"
  "electron_42"
  "electron_43"
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
