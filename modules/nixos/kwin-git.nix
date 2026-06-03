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

          # The three NixOS-specific patches (QPA wrapper, executable unwrapping,
          # CAP_SYS_NICE ambient-set lowering) are written against the stable
          # release tree and will not apply cleanly to master after the KWin 6.x
          # source reorganisation.  Re-add them once ported to the new paths.
          patches = [ ];
        });
      });
    })
  ];
}
