{ pkgs, ... }:

# `sudo coda-carry`: bundle the host's coda-rust worktrees for the sandbox
# (README: "Bringing host worktrees over").
{
  environment.systemPackages = [ (pkgs.callPackage ./coda-carry-package.nix { }) ];
}
