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
          };
        };
      };
    };
  };

}
