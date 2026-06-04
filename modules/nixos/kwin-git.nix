{ ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
      kdePackages = prev.kdePackages.overrideScope (kfinal: kprev: {
        kwin = kprev.kwin.overrideAttrs (old: {
          patches = (old.patches or []) ++ [
            ./kwin-patches/0004-libinput-guard-empty-outputs.patch
          ];
        });
      });
    })
  ];
}
