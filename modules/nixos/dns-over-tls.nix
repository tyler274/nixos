{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Quad9 DNS-over-TLS (https://quad9.net/) - primary resolvers.
  quad9Dns = [
    "9.9.9.9#dns.quad9.net"
    "149.112.112.112#dns.quad9.net"
  ];

  # Cloudflare DNS-over-TLS (https://1.1.1.1/) - encrypted fallback when Quad9
  # is unreachable. Do not use router/VPN DHCP DNS here; those leak plaintext
  # and bypass the Quad9/Cloudflare chain.
  cloudflareDns = [
    "1.1.1.1#cloudflare-dns.com"
    "1.0.0.1#cloudflare-dns.com"
  ];
in
{
  config = lib.mkIf (config.networking.networkmanager.enable or false) {
    networking.nameservers = quad9Dns;

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
        FallbackDNS = cloudflareDns;
      };
    };
  };
}
