# Self-hosted Ubiquiti UniFi Network controller (control plane for APs,
# switches, and gateways). The upstream NixOS module runs the controller as
# the dynamic `unifi` user with state in /var/lib/unifi.
#
# Both packages here are unfree (UniFi EULA, MongoDB SSPL); common.nix already
# sets nixpkgs.config.allowUnfree = true so no predicate is needed.

{ pkgs, ... }:

{
  services.unifi = {
    enable = true;
    unifiPackage = pkgs.unifi;
    # The module default (pkgs.mongodb-7_0) is built from source and is not
    # substituted by cache.nixos.org — it needs tens of GB of RAM/disk to
    # compile. mongodb-ce repackages the upstream prebuilt binaries instead.
    # Note mongod requires AVX; fine on real hardware, but a VM must expose
    # the flag or mongod crashes on startup.
    mongodbPackage = pkgs.mongodb-ce;
    # Opens the device-facing ports only: 8080/tcp (inform), 8880+8843/tcp
    # (guest portal HTTP/HTTPS), 6789/tcp (mobile speedtest), 3478/udp (STUN),
    # 10001/udp (L2 discovery).
    openFirewall = true;
    # Cap the JVM so the controller doesn't balloon on a shared box; it runs
    # comfortably in 1 GiB for home-scale deployments.
    maximumJavaHeapSize = 1024;
  };

  # openFirewall deliberately does NOT expose the web UI. 8443 is the HTTPS
  # admin interface; drop this if you only reach it over a VPN/tunnel.
  networking.firewall.allowedTCPPorts = [ 8443 ];
}
