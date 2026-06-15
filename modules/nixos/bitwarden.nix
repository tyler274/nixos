{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.bitwarden;

  bitwardenLib = import ../lib/bitwarden.nix {
    inherit pkgs lib;
    item = cfg.liberaItem;
  };
in
{
  options.bitwarden = {
    enable = lib.mkEnableOption "Bitwarden integration";

    liberaItem = lib.mkOption {
      type = lib.types.str;
      default = "libera.chat";
      description = ''
        Bitwarden vault item name used by the Libera IRC password helper.
        Must match {option}`bitwarden.liberaItem` in Home Manager.
      '';
    };

    halloy.firejail.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Allow Halloy (under firejail) to run the Bitwarden CLI password helper
        for Libera SASL authentication.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.halloy.firejail.enable) {
    environment.etc."firejail/halloy.local".text = bitwardenLib.firejailLocal;
  };
}
