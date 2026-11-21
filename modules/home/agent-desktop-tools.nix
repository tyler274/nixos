{ pkgs, inputs, ... }:

# Lets a terminal agent (Claude Code, Codex in an Orca terminal, a cron job)
# see and drive the Plasma Wayland session: kw-focus, kw-input, kw-screenshot,
# kw-mpris, firefox-tabs, kw-press-play. Source and the reasoning behind each
# tool: https://github.com/tyler274/kde-wayland-agent-tools
#
# kw-input writes to /dev/uinput, so the host needs hardware.uinput.enable and
# the user in the uinput group (modules/nixos/desktop-common.nix and
# hosts/cyrene/default.nix). KWin picks the virtual device up like real hardware.
{
  home.packages = [
    inputs.kde-wayland-agent-tools.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
