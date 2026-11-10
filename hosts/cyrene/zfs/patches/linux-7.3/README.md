Linux 7.3 compat for OpenZFS 2.4.4, vendored from Ubuntu's zfs-linux
`import/2.4.4-1ubuntu4` (debian/patches). Backports of OpenZFS master
d966f3dd8, 315bc75af, 6e2fa4bc8, cd3699d30, a128b8a07. Tracking:
https://github.com/openzfs/zfs/issues/19032. Delete once nixpkgs' zfs_2_4
supports 7.3 (boot.nix warns).
