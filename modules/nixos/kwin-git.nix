{ inputs, ... }:

{
  # Build KWin from the master branch on GitHub.
  # kdePackages is a makeScope, so overrideScope keeps internal cross-package
  # references consistent (e.g. kwin depending on other kdePackages members).
  nixpkgs.overlays = [
    (final: prev: {
      kdePackages = prev.kdePackages.overrideScope (kfinal: kprev: {
        kwin = kprev.kwin.overrideAttrs (_: {
          version = "git-${inputs.kwin-src.shortRev}";
          src = inputs.kwin-src;

          # Same NixOS-specific patches carried by nixpkgs (written against
          # 6.6.5, the current unstable version).  Master is close enough that
          # they should apply cleanly; drop any that conflict after a major bump.
          patches = [
            ./kwin-patches/0003-plugins-qpa-allow-using-nixos-wrapper.patch
            ./kwin-patches/0001-NixOS-Unwrap-executable-name-for-.desktop-search.patch
            ./kwin-patches/0001-Lower-CAP_SYS_NICE-from-the-ambient-set.patch
          ];
        });
      });
    })
  ];
}
