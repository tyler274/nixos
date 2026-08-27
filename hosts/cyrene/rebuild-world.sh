#!/usr/bin/env bash
# Cyrene from-source znver5 world-rebuild - run from /etc/nixos (or anywhere,
# via a symlink/alias) on Cyrene itself. Wraps `nixos-rebuild boot` with the
# flags this rebuild campaign needs; see hosts/cyrene/default.nix for why
# each one is set the way it is:
#
#   extra-system-features gccarch-znver5   opt into -march=znver5 builds
#                                           (declared in default.nix's
#                                           nix.settings.system-features)
#   keep-going true                        collect every independent build
#                                           failure in one pass instead of
#                                           stopping at the first
#   max-jobs 8 / cores 16                  leave headroom on the 9950X3D
#                                           (32 threads) for the desktop
#                                           session while building
#   substituters cache.nixos.org           skip narinfo queries to caches
#                                           that can never hit a znver5
#                                           build (see default.nix)
#   narinfo-cache-negative-ttl 86400       cache "not in this cache" for
#                                           24h instead of the 1h default,
#                                           so repeated fix-and-rebuild
#                                           runs don't re-query known misses
#   --log-format internal-json -v | nom    structured output piped through
#                                           nix-output-monitor for a live
#                                           build tree instead of a wall of
#                                           interleaved log lines
#
# Any extra arguments are forwarded to nixos-rebuild, e.g.:
#   ./rebuild-world.sh --option max-jobs 4
#
# Requires nix-output-monitor (`nom`), already installed system-wide via
# modules/nixos/common.nix.

set -euo pipefail

sudo nixos-rebuild boot --flake /etc/nixos#Cyrene \
  --option extra-system-features gccarch-znver5 \
  --option keep-going true \
  --option max-jobs 8 --option cores 16 \
  --option substituters https://cache.nixos.org \
  --option narinfo-cache-negative-ttl 86400 \
  --log-format internal-json -v "$@" |& nom --json
