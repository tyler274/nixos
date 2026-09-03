# Chromium-family and Mozilla browsers ship their own allocators
# (PartitionAlloc, mozjemalloc) and cannot coexist with a system-wide
# malloc preloaded via /etc/ld-nix.so.preload (environment.memoryAllocator).
#
# Verified 2026-08 on this host, injecting that preload with bwrap so the
# test matches the NixOS mechanism rather than LD_PRELOAD (which content
# processes can drop):
#
#   Edge / Electron (Signal, Bitwarden, Pocket Casts)
#     libc / graphene / graphene-light  - start
#     mimalloc                          - SIGSEGV (Edge) or SIGTRAP (Electron)
#   Firefox / Thunderbird (firefox-bin, thunderbird-bin)
#     all four                          - headless start; still wrapped
#                                         because mozjemalloc vs ld.so.preload
#                                         is a known class of content-process
#                                         crashes (scudo/graphene on other
#                                         versions) and the wrap is a no-op
#                                         when the preload file is absent.
#
# Hiding the preload in a mount namespace (empty file bind-mounted over
# /etc/ld-nix.so.preload) restores Edge and Signal under mimalloc. Package
# overrides can't opt a derivation out of ld.so.preload at build time - the
# file is applied by glibc at runtime - so each launcher is wrapped with
# bubblewrap. Firejail's --blacklist of the same path covers the
# programs.firejail wrappers (see desktop-common.nix); without it, firejail
# noroot blocks the inner bwrap.
#
# Wrap `electron` / `electron_N` with the CAP_SYS_ADMIN helper, not
# bwrap. Leaf-app launchers (Signal, Bitwarden, …) still get bwrap so
# vendored copies of Electron are covered; nixpkgs apps such as Mullvad
# bake `${electron}/bin/electron` into makeWrapper, which then execs
# electron-unwrapped's libexec ELF. bwrap around electron maps uid 0 out
# of the user namespace and Mullvad reports "Failed to verify root
# ownership of socket". The helper only unshares a mount namespace (see
# hide-system-malloc.c and security.wrappers in common.nix). Wrapping
# both `$out/bin/electron` and `$out/libexec/electron/electron` is
# required: the crash command line is the libexec path, and symlinkJoin
# otherwise leaves that as a symlink into electron-unwrapped.
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

    # systemd BindReadOnlyPaths (and tests) can already hide the preload
    # with an empty file. Skip bwrap in that case: services such as
    # flaresolverr set RestrictNamespaces=user and drop CAP_SYS_ADMIN, so
    # clone(CLONE_NEWUSER) fails ("No permissions to create a new
    # namespace") and Chromium never starts.
    if [ ! -s /etc/ld-nix.so.preload ]; then
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

  # Mullvad (and anything else that stats a root-owned Unix socket) cannot
  # use the bwrap wrap: host uid 0 is unmapped in an unprivileged user
  # namespace, so the socket appears to be owned by nobody. This helper
  # is security.wrappers.hide-system-malloc (CAP_SYS_ADMIN, dropped before
  # exec) and only creates a mount namespace.
  capWrapperTemplate = prev.writeText "hide-system-malloc-cap.sh" ''
    #!${prev.runtimeShell}
    real="@real@"
    helper=/run/wrappers/bin/hide-system-malloc
    if [ ! -x "$helper" ]; then
      echo "hide-system-malloc: $helper missing; rebuild with security.wrappers" >&2
      exec "$real" "$@"
    fi
    exec "$helper" "$real" "$@"
  '';

  hideSystemMallocExec = prev.runCommandCC "hide-system-malloc" { } ''
    mkdir -p $out/bin
    $CC -O2 -Wall -Werror \
      -DEMPTY_PRELOAD='"${emptyPreload}"' \
      -o $out/bin/hide-system-malloc ${./hide-system-malloc.c}
  '';

  # Preserve callPackage/wrapFirefox surface so later overlays and HM
  # (`package.override`, chromium.sandbox, firefox-bin.unwrapped) keep working
  # on top of the symlinkJoin.
  keepInterface =
    wrapFn: orig: wrapped:
    wrapped
    // lib.optionalAttrs (orig ? override) {
      override = args: wrapFn (orig.override args);
    }
    // lib.optionalAttrs (orig ? overrideAttrs) {
      overrideAttrs = f: wrapFn (orig.overrideAttrs f);
    }
    // lib.optionalAttrs (orig ? sandbox) { inherit (orig) sandbox; }
    // lib.optionalAttrs (orig ? browser) { inherit (orig) browser; }
    # unwrapped is re-wrapped for electron in wrapElectron; other packages
    # keep the original (firefox-bin.unwrapped, etc.).
    // lib.optionalAttrs (orig ? unwrapped) { inherit (orig) unwrapped; };

  wrapWith =
    template: pkg:
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

            wrap_file() {
              local dest=$1
              [ -e "$dest" ] || [ -L "$dest" ] || return 0
              [ -d "$dest" ] && return 0
              case "$(basename "$dest")" in
                *sandbox*) return 0 ;;
              esac
              local real
              real=$(readlink -f "$dest")
              [ -n "$real" ] && [ -x "$real" ] || return 0
              mkdir -p "$(dirname "$dest")"
              rm -f "$dest"
              substitute ${template} "$dest" --subst-var-by real "$real"
              chmod +x "$dest"
            }

            # electron's $out/libexec is a symlink into electron-unwrapped.
            # Replace store-symlinked dirs with a directory of symlinks so
            # wrap_file can override the ELF without copying the tree.
            relink_dir() {
              local dir=$1
              [ -L "$dir" ] || return 0
              local target
              target=$(readlink -f "$dir")
              [ -d "$target" ] || return 0
              rm -f "$dir"
              mkdir -p "$dir"
              local e
              for e in "$target"/*; do
                [ -e "$e" ] || [ -L "$e" ] || continue
                ln -s "$e" "$dir/$(basename "$e")"
              done
            }

            for bin in "$out"/bin/*; do
              wrap_file "$bin"
            done

            relink_dir "$out/libexec"
            relink_dir "$out/libexec/electron"
            for f in "$out"/libexec/*; do
              wrap_file "$f"
            done
            wrap_file "$out/libexec/electron/electron"
            wrap_file "$out/libexec/electron/chrome"

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
      keepInterface (wrapWith template) pkg wrapped;

  hideSystemMalloc = wrapWith wrapperTemplate;
  hideSystemMallocNoUserns = wrapWith capWrapperTemplate;

  # Preserve passthru.unwrapped as a wrapped derivation so consumers that
  # exec electron-unwrapped's libexec path still go through the helper.
  wrapElectron =
    pkg:
    if !lib.isDerivation pkg then
      pkg
    else
      let
        wrapped = hideSystemMallocNoUserns pkg;
      in
      wrapped
      // lib.optionalAttrs (pkg ? unwrapped && lib.isDerivation pkg.unwrapped) {
        unwrapped = hideSystemMallocNoUserns pkg.unwrapped;
      };
in
{
  hide-system-malloc-exec = hideSystemMallocExec;
  mullvad-vpn = hideSystemMallocNoUserns prev.mullvad-vpn;
}
# Do not filterAttrs over `prev` - that forces every nixpkgs attribute.
# Electron itself uses the mount-ns helper (no user ns). Leaf apps that
# vendor their own Electron still need the bwrap wrap below.
#
# Wrap versioned slots only, not `electron`. all-packages sets
# `electron = electron_43` against the final pkgs, so overlaying both
# wraps the alias a second time (helper's real= becomes another wrap).
// lib.genAttrs [
  "electron_42"
  "electron_43"
] (n: wrapElectron prev.${n})
// lib.genAttrs [
  "firefox"
  "firefox-bin"
  "thunderbird"
  "thunderbird-bin"
  "chromium"
  "microsoft-edge"
  "discord"
  "signal-desktop"
  "pocket-casts"
] (n: hideSystemMalloc prev.${n})
# Bitwarden patches `app.getPath("exe")` to its own `$out/bin/bitwarden` and
# writes that path into `~/.config/autostart/bitwarden.desktop`. A symlinkJoin
# wrap around `prev.bitwarden-desktop` is skipped on login. Rebuild against
# wrapped `electron_43` so the inner launcher still hides ld.so.preload.
// {
  bitwarden-desktop = hideSystemMalloc (
    prev.bitwarden-desktop.override { electron_43 = final.electron_43; }
  );
}
