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
    bitwarden.liberaPasswordCommand = "${pkgs.bash}/bin/bash ${bitwardenLib.passwordScript}";

    home.packages = with pkgs; [
      bitwarden-desktop
      bitwarden-cli
    ];

    # Bitwarden writes this file from `app.getPath("exe")`. Keep HM as the
    # owner so login always uses the electron-wrapped launcher. force=true
    # used to leave `bitwarden.desktop.hm-backup` behind; systemd's xdg
    # autostart generator still starts that leftover (unwrapped) copy.
    xdg.configFile."autostart/bitwarden.desktop" = {
      force = true;
      text = ''
        [Desktop Entry]
        Type=Application
        Name=Bitwarden
        Comment=Bitwarden startup script
        Exec=${pkgs.bitwarden-desktop}/bin/bitwarden --autostart
        StartupNotify=false
        Terminal=false
      '';
    };

    home.activation.cleanupBitwardenAutostartBackup = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      backup="${config.home.homeDirectory}/.config/autostart/bitwarden.desktop.hm-backup"
      if [ -e "$backup" ]; then
        run rm -f "$backup"
      fi
      if command -v systemctl >/dev/null 2>&1; then
        run systemctl --user stop 'app-bitwarden.desktop.hm-backup@autostart.service' || true
        run systemctl --user reset-failed 'app-bitwarden@autostart.service' || true
      fi
    '';

    home.sessionVariables.SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/.bitwarden-ssh-agent.sock";

    xdg.mimeApps.defaultApplications."x-scheme-handler/bitwarden" = [ "bitwarden.desktop" ];
  };
}
