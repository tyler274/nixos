{
  config,
  lib,
  ...
}:

let
  # Mullvad DNS-over-TLS (port 853, hostname dns.mullvad.net). Matches the
  # Mullvad VPN service already enabled on desktop hosts.
  mullvadDns = [
    "194.242.2.2#dns.mullvad.net"
    "194.242.2.3#dns.mullvad.net"
  ];
in
{
  config = lib.mkIf (config.networking.networkmanager.enable or false) {
    networking.nameservers = mullvadDns;

    services.resolved = {
      enable = true;
      settings.Resolve = {
        DNSOverTLS = "true";
        DNSSEC = "true";
        # Route all lookups through the encrypted upstream resolvers above.
        Domains = [ "~." ];
        FallbackDNS = mullvadDns;
      };
    };
  };
}
