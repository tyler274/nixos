# Cursor IDE WSL requirements (do not remove without replacement):
#
#   1. `programs.nix-ld.enable` (inherited from modules/nixos/common.nix) lets
#      Cursor's prebuilt remote-server binary load standard glibc/ld-linux.
#   2. The `bashWrapper` derivation below puts a curated PATH (gnugrep,
#      coreutils, gnutar, gzip, getconf, gnused, procps, which, gawk, wget,
#      curl, util-linux) onto `/bin/bash`, which Cursor's WSL connection
#      shell-execs to bootstrap the remote server.
#   3. `wsl.wrapBinSh = true` replaces /bin/sh with a NixOS-aware shell so
#      Cursor's subprocesses can shell out.
#   4. `wsl.extraBin` exposes the wrapped bash at /bin/bash (the entry point
#      Cursor uses to start a remote session).
#
# Removing any of the four breaks Cursor's WSL remote.

{ config, pkgs, lib, ... }:

let
  bashWrapper = pkgs.runCommand "nixos-wsl-bash-wrapper"
    { nativeBuildInputs = [ pkgs.makeWrapper ]; }
    ''
      makeWrapper ${pkgs.bashInteractive}/bin/bash $out/bin/bash \
        --prefix PATH ':' ${lib.makeBinPath (with pkgs; [
          gnugrep coreutils gnutar gzip
          getconf gnused procps which gawk wget curl
          util-linux
        ])}
    '';
in
{
  imports = [
    ../../modules/nixos/common.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "eula";

  wsl = {
    enable = true;
    defaultUser = "luluco";
    wrapBinSh = true;
    extraBin = [
      {
        name = "bash";
        src = "${bashWrapper}/bin/bash";
      }
    ];

    # Re-register the WSLInterop binfmt entry on every activation. Without
    # this, running Windows .exe files (Cursor.exe, notepad.exe, code.exe,
    # explorer.exe, etc.) from inside WSL fails with
    # "cannot execute binary file: Exec format error" whenever any other
    # NixOS module touches boot.binfmt.registrations.
    interop = {
      register = true;
      includePath = true;
    };
  };

  users.users.luluco = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  home-manager.users.luluco = { ... }: {
    imports = [
      ../../modules/home/common.nix
    ];
    home.stateVersion = "25.11";
  };

  system.stateVersion = "25.11";
}
