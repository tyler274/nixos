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
    enable = lib.mkEnableOption "Bitwarden password manager";

    liberaItem = lib.mkOption {
      type = lib.types.str;
      default = "libera.chat";
      description = ''
        Bitwarden vault item name searched by {command}`bw get password`
        for Libera IRC SASL authentication.
      '';
    };

    liberaPasswordScript = lib.mkOption {
      type = lib.types.path;
      internal = true;
      visible = false;
      description = "Nix store path to the Libera IRC password helper script.";
    };

    liberaPasswordCommand = lib.mkOption {
      type = lib.types.str;
      internal = true;
      visible = false;
      description = ''
        Shell command Halloy runs to fetch the Libera SASL password.
        Invoked explicitly with bash because Halloy executes commands via sh -c.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    bitwarden.liberaPasswordScript = bitwardenLib.passwordScript;
    bitwarden.liberaPasswordCommand =
      "${pkgs.bash}/bin/bash ${bitwardenLib.passwordScript}";

    home.packages = with pkgs; [
      bitwarden-desktop
      bitwarden-cli
    ];

    home.sessionVariables.SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/.bitwarden-ssh-agent.sock";

    xdg.mimeApps.defaultApplications."x-scheme-handler/bitwarden" = [ "bitwarden.desktop" ];
  };
}
