# Not architecture-related, and not a package bug: the local Nix store got
# nodejs-slim-24.18.1 into a state where three of its five outputs (out,
# npm, corepack) are already valid, but the other two (dev, libv8) are not
# (likely from an earlier interrupted --keep-going run where different
# downstream consumers pulled different output subsets). In that mixed
# state, every rebuild attempt - via `nix build`, `nix-store --realise`, or
# nixos-rebuild - deterministically fails at the final output-check step:
#
#   error: derivation '...nodejs-slim-24.18.1.drv' output check for 'libv8'
#   contains output name 'corepack', but this is not a valid output of this
#   derivation. (Valid outputs are [dev, libv8].)
#
# nodejs.nix's outputChecks legitimately reference all five output names
# (out/libv8/npm/corepack/dev) cross-referentially, but the daemon
# validates them against only the outputs actually being (re)built in this
# invocation (the two missing ones) rather than the derivation's full
# declared `outputs` list - a real Nix daemon bug (same family as
# NixOS/nix#6572, NixOS/nix#8188: partial-output multi-output derivation
# state confuses the build-goal machinery), not something fixable in the
# package itself. Confirmed deterministic and tool-independent; requesting
# all outputs together (`^*`) doesn't help because the daemon still only
# rebuilds what's missing and reuses what's already valid, hitting the same
# code path either way.
#
# The already-valid out/npm/corepack outputs back the live, currently
# booted system (nodejs-24.18.1 is a GC root via /run/current-system and
# home-manager), so deleting them to force a from-scratch rebuild is not
# safe. Instead, bump the derivation hash via a harmless nonce env var: the
# new derivation's outputs are all-new store paths that have never been
# built, so the rebuild realizes all five atomically from a clean slate,
# never entering the mixed valid/invalid state that triggers the bug. This
# does not touch or invalidate the old, currently-live paths - they're
# simply orphaned (eligible for GC once no longer referenced) while the
# fresh build proceeds independently.
#
# Safe to drop this file once the current from-source world rebuild
# reaches a clean generation switch; it's a one-time store-state escape
# hatch, not a permanent fix.
final: prev: {
  nodejs-slim = prev.nodejs-slim.overrideAttrs (old: {
    env = (old.env or { }) // {
      __znver5RebuildNonce = "2026-08-14-partial-output-workaround";
    };
  });
}
