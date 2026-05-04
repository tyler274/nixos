{ config, pkgs, inputs, lib, ... }:

{
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };
  nix.gc = {
    automatic = true;
    dates = "hourly";
    options = "--delete-older-than 30d";
  };

  nixpkgs.config.allowUnfree = true;

  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  security.rtkit.enable = true;

  programs = {
    nix-ld.enable = true;
    ssh.startAgent = true;
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    git
    nix-index
  ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-backup";
    extraSpecialArgs = { inherit inputs; };
  };
}
