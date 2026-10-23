{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ccache;

  # Upstream's programs.ccache registers `nix-ccache` as a setgid wrapper around
  # a Perl script, which security.wrappers' ensure-wrapper-integrity check now
  # rejects ("not an ELF"). Re-implement the same argument whitelist + scrubbed
  # environment as a tiny C program so the wrapper target is a real ELF.
  nixCcache = pkgs.runCommandCC "nix-ccache" { } ''
    mkdir -p $out/bin
    cat > nix-ccache.c <<'EOF'
    #include <string.h>
    #include <unistd.h>

    #define CCACHE "${pkgs.ccache}/bin/ccache"

    static char *const envp[] = { "CCACHE_DIR=${cfg.cacheDir}", NULL };

    static void help(void) {
      char *const argv[] = { "ccache", "-h", NULL };
      execve(CCACHE, argv, envp);
      _exit(127);
    }

    static char *untaint(const char *v) {
      if (!strcmp(v, "-C") || !strcmp(v, "--clear")) return "-C";
      if (!strcmp(v, "-V") || !strcmp(v, "--version")) return "-V";
      if (!strcmp(v, "-s") || !strcmp(v, "--show-stats")) return "-s";
      if (!strcmp(v, "-z") || !strcmp(v, "--zero-stats")) return "-z";
      help();
      return NULL;
    }

    int main(int argc, char **argv) {
      char *args[argc + 1];
      args[0] = "ccache";
      for (int i = 1; i < argc; i++) args[i] = untaint(argv[i]);
      args[argc] = NULL;
      execve(CCACHE, args, envp);
      return 127;
    }
    EOF
    $CC -O2 -Wall -Werror -o $out/bin/nix-ccache nix-ccache.c
  '';
in
{
  nix.settings.extra-sandbox-paths = [ cfg.cacheDir ];

  programs.ccache.enable = true;

  security.wrappers.nix-ccache.source = lib.mkForce "${nixCcache}/bin/nix-ccache";

  # Harden the ccache wrapper: fail loudly if the cache dir is missing or
  # unwritable rather than silently breaking compiler tests in the sandbox.
  # The cache dir must exist with: chown root:nixbld /var/cache/ccache && chmod 0770
  nixpkgs.overlays = [
    (self: super: {
      ccacheWrapper = super.ccacheWrapper.override {
        extraConfig = ''
          export CCACHE_COMPRESS=1
          export CCACHE_DIR="${cfg.cacheDir}"
          export CCACHE_UMASK=007
          if [ ! -d "$CCACHE_DIR" ]; then
            echo "====="
            echo "Directory '$CCACHE_DIR' does not exist"
            echo "Please create it with:"
            echo "  sudo mkdir -m0770 '$CCACHE_DIR'"
            echo "  sudo chown root:nixbld '$CCACHE_DIR'"
            echo "====="
            exit 1
          fi
          if [ ! -w "$CCACHE_DIR" ]; then
            echo "====="
            echo "Directory '$CCACHE_DIR' is not accessible for user $(whoami)"
            echo "Please verify its access permissions"
            echo "====="
            exit 1
          fi
        '';
      };
    })
  ];
}
