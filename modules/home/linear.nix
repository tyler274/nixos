{ pkgs, ... }:
let
  linear = pkgs.callPackage ../../packages/linear-bottles { };
in
{
  home.packages = [ linear ];

  xdg.desktopEntries.linear-bottles = {
    name = "Linear";
    comment = "Official Linear desktop app via Bottles";
    exec = "${linear}/bin/linear-bottles %u";
    icon = "linear-bottles";
    terminal = false;
    categories = [ "Office" "ProjectManagement" ];
    mimeType = [ "x-scheme-handler/linear" ];
  };

  xdg.mimeApps.defaultApplications."x-scheme-handler/linear" = [ "linear-bottles.desktop" ];
}
