# Not architecture-related, and not a package bug: the local Nix store has
# multi-output derivations in a mixed valid/invalid state (likely from an
# earlier interrupted --keep-going run where different downstream consumers
# pulled different output subsets). In that mixed state, every rebuild
# attempt - via `nix build`, `nix-store --realise`, or nixos-rebuild -
# deterministically fails at the final output-check step. Two packages have
# hit this so far:
#
#   nodejs-slim-24.18.1: out/npm/corepack valid, dev/libv8 not.
#     error: derivation '...nodejs-slim-24.18.1.drv' output check for 'libv8'
#     contains output name 'corepack', but this is not a valid output of this
#     derivation. (Valid outputs are [dev, libv8].)
#
#   postgresql-18.6: out/lib/man valid; debug/dev/doc/jit/plperl/plpython3/pltcl
#     not. Blocks psycopg, pytest-postgresql, sqlframe, narwhals, and thereby
#     calibre / home-manager.
#     error: derivation '...postgresql-18.6.drv' output check for 'doc'
#     contains output name 'man', but this is not a valid output of this
#     derivation. (Valid outputs are [debug, dev, doc, jit, plperl, plpython3, pltcl].)
#
# The packages' outputChecks legitimately cross-reference sibling outputs,
# but the daemon validates them against only the outputs actually being
# (re)built in this invocation rather than the derivation's full declared
# `outputs` list - a real Nix daemon bug (same family as NixOS/nix#6572,
# NixOS/nix#8188: partial-output multi-output derivation state confuses the
# build-goal machinery), not something fixable in the package itself.
# Confirmed deterministic and tool-independent; requesting all outputs
# together (`^*`) doesn't help because the daemon still only rebuilds what's
# missing and reuses what's already valid, hitting the same code path
# either way.
#
# Already-valid outputs back the live, currently booted system (GC roots via
# /run/current-system and home-manager), so deleting them to force a
# from-scratch rebuild is not safe. Instead, bump the derivation hash via a
# harmless nonce env var: the new derivation's outputs are all-new store
# paths that have never been built, so the rebuild realizes every output
# atomically from a clean slate, never entering the mixed valid/invalid
# state that triggers the bug. This does not touch or invalidate the old,
# currently-live paths - they're simply orphaned (eligible for GC once no
# longer referenced) while the fresh build proceeds independently.
#
# Safe to drop this file once the current from-source world rebuild
# reaches a clean generation switch; it's a one-time store-state escape
# hatch, not a permanent fix.
final: prev:
let
  bumpNonce = nonce: old: {
    env = (old.env or { }) // {
      __znver5RebuildNonce = nonce;
    };
  };
in
{
  nodejs-slim = prev.nodejs-slim.overrideAttrs (bumpNonce "2026-08-14-partial-output-workaround");

  # postgresql is currently an alias of postgresql_18; override both so
  # services.postgresql.package and python packages that take postgresql_18
  # realize the same new derivation.
  postgresql_18 = prev.postgresql_18.overrideAttrs (bumpNonce "2026-09-08-partial-output-workaround");
  postgresql =
    if prev.postgresql == prev.postgresql_18 then
      final.postgresql_18
    else
      prev.postgresql.overrideAttrs (bumpNonce "2026-09-08-partial-output-workaround");
}
