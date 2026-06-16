{
  config,
  pkgs,
  lib,
  ...
}:

{
  config = lib.mkIf config.bitwarden.enable {
    programs.halloy = {
      enable = true;
      settings = {
        servers = {
          libera = {
            nickname = config.home.username;
            server = "irc.libera.chat";
            use_tls = true;
            channels = [ "#gssapi" ];
            sasl = {
              plain = {
                # Bitwarden item from bitwarden.liberaItem; SASL username is the IRC nick.
                username = config.home.username;
                # Requires a one-time `bw login`. Reload config after unlocking the vault.
                password_command = config.bitwarden.liberaPasswordCommand;
                disconnect_on_failure = true;
              };
            };
          };
        };
      };
    };

    # Drop the read-only copy so Home Manager can relink config.toml each generation.
    home.activation.prepareHalloyConfig = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
      config_file="${config.xdg.configHome}/halloy/config.toml"
      if [ -f "$config_file" ] && [ ! -L "$config_file" ]; then
        run rm -f "$config_file"
      fi
    '';

    # Server settings (including password_command) are managed in Nix. Home Manager
    # symlinks config.toml into the read-only Nix store, so replace it with a real
    # read-only copy (same approach as fixSshConfigPermissions in common.nix).
    home.activation.secureHalloyConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      config_dir="${config.xdg.configHome}/halloy"
      config_file="$config_dir/config.toml"
      expected_cmd='${config.bitwarden.liberaPasswordScript}'

      run install -d -m 0700 "$config_dir"

      if [ ! -e "$config_file" ]; then
        exit 0
      fi

      if [ -L "$config_file" ]; then
        src="$(readlink -f "$config_file")"
      else
        src="$config_file"
      fi

      if ! ${pkgs.gnugrep}/bin/grep -Fq "$expected_cmd" "$src"; then
        echo "error: $config_file password_command does not match the Nix store helper" >&2
        exit 1
      fi

      if [ -L "$config_file" ]; then
        run rm -f "$config_file"
        run install -m 0444 "$src" "$config_file"
      fi
    '';
  };
}
