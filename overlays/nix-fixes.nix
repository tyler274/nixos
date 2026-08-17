# Cyrene's scratch build dir (hosts/cyrene/scratch.nix) is XFS, and XFS
# hard-caps symlink targets at 1024 bytes (XFS_SYMLINK_MAXLEN — an on-disk
# format constant carried over from Irix, enforced unconditionally in
# xfs_symlink.c's bounds checks on every kernel; not a mkfs/mount-tunable).
# Confirmed directly on a loopback XFS fs: 1023-byte symlink targets
# succeed, 1024+ fail with ENAMETOOLONG.
#
# nix's own unit tests hit this ceiling: src/libutil-tests/file-system-at.cc's
# `TEST(readLinkAt, works)` creates "medium" (2048-byte) and "long"
# (4095-byte) symlink targets to exercise readlinkat()'s buffer-growth path,
# so it fails with ENAMETOOLONG on the XFS-backed build scratch dir. This is
# a real gap in nixpkgs' pinned nix 2.34.8: upstream later taught this test
# to catch ENAMETOOLONG and skip the long-target cases on filesystems that
# don't support them, but 2.34.8 predates that fix, and the whole test is
# one monolithic TEST() — there's no sub-case granularity to filter out via
# --gtest_filter, so the entire test must be excluded, including its
# unrelated basic-readlink and error-case assertions.
#
# building `nix` itself is unavoidable as part of the from-source
# znver5 world rebuild, and `nix-everything`'s `doCheck = true` gates the
# whole package on `nix-util-tests.tests.run` passing (see
# pkgs/tools/package-management/nix/modular/packaging/everything.nix), so
# without this the entire nix build — and therefore nixos-rebuild — fails
# outright on an XFS scratch dir.
#
# Safe to drop once nixpkgs advances past nix 2.34.8 to a release containing
# upstream's ENAMETOOLONG-skip fix for this test.
final: prev: {
  nix = prev.nix.overrideAllMesonComponents (
    finalAttrs: prevAttrs:
    prev.lib.optionalAttrs (prevAttrs.pname or "" == "nix-util-tests") {
      excludedTestPatterns = (prevAttrs.excludedTestPatterns or [ ]) ++ [ "readLinkAt.works" ];
    }
  );
}
