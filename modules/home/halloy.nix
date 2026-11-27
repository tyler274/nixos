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
      # Installed system-wide behind firejail (desktop-common.nix).
      package = null;
      settings = {
        servers = {
          libera = {
            nickname = config.home.username;
            server = "irc.libera.chat";
            use_tls = true;
            channels = [ "#gssapi" ];
          };
        };
      };
    };
  };

}
