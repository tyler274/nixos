{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Mullvad DNS-over-TLS (port 853, hostname dns.mullvad.net). Matches the
  # Mullvad VPN service already enabled on desktop hosts.
  mullvadDns = [
    "194.242.2.2#dns.mullvad.net"
    "194.242.2.3#dns.mullvad.net"
  ];

  # Quad9 DNS-over-TLS (https://quad9.net/) — encrypted fallback when Mullvad
  # resolvers are unreachable. Do not use router/VPN DHCP DNS here; those leak
  # plaintext and bypass the Mullvad/Quad9 chain.
  quad9Dns = [
    "9.9.9.9#dns.quad9.net"
    "149.112.112.112#dns.quad9.net"
  ];
in
{
  config = lib.mkIf (config.networking.networkmanager.enable or false) {
    networking.nameservers = mullvadDns;

    # Stop NetworkManager from registering DHCP/VPN resolvers (e.g. 192.168.1.1,
    # 10.64.0.1) with systemd-resolved. Per-link DNS takes precedence over
    # FallbackDNS, so we ignore auto DNS on connect and clear anything already
    # pushed for the interface.
    networking.networkmanager.dispatcherScripts = [
      {
        source = pkgs.writeShellScript "ignore-link-dns" ''
          case "''${2:-}" in
            up|dhcp4-change|dhcp6-change|vpn-up)
              if [ -n "''${CONNECTION_UUID:-}" ]; then
                ${pkgs.networkmanager}/bin/nmcli connection modify "$CONNECTION_UUID" \
                  ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes \
                  2>/dev/null || true
              fi
              ${pkgs.systemd}/bin/resolvectl dns "$1" "" 2>/dev/null || true
              ${pkgs.systemd}/bin/resolvectl domain "$1" "" 2>/dev/null || true
              ;;
          esac
        '';
      }
    ];

    services.resolved = {
      enable = true;
      settings.Resolve = {
        DNSOverTLS = "true";
        DNSSEC = "true";
        # Route all lookups through the encrypted upstream resolvers above.
        Domains = [ "~." ];
        FallbackDNS = quad9Dns;
      };
    };
  };
}
