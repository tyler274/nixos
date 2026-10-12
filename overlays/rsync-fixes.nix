# rsync 3.5.0's partial-protected-regular-retry-linux check fails on i686.
# The LD_PRELOAD hook interposes open/openat/fstatat. A 32-bit build with
# _FILE_OFFSET_BITS=64 calls the distinct open64/openat64/fstatat64 symbols,
# so the hook loads and then reports that the receiver never opened the
# partial file with O_CREAT. On LP64 those names are aliases and the same
# test passes. The patch interposes the *64 symbols only when __LP64__ is
# unset, and leaves the 64-bit hook unchanged.
#
# Drop once nixpkgs ships an rsync whose test does this itself.
final: prev: {
  rsync = prev.rsync.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./patches/rsync/0001-interpose-open64-on-32-bit.patch
    ];
  });
}
