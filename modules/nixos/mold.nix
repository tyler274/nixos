{ pkgs, ... }:

{
  # Make mold available to root and system services (provides ld.mold, mold).
  environment.systemPackages = [ pkgs.mold ];

  # Tell GCC/Clang (>= 12) to use mold for all interactive compilation in
  # any shell session on this machine (nixos-rebuild, manual make/cmake runs,
  # cargo builds outside nix sandboxes, etc.).
  environment.variables = {
    CC_LD  = "mold";
    CXX_LD = "mold";
  };
}
